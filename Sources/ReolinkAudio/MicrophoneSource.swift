import AVFoundation
import Foundation

/// The Mac microphone, resampled to the format the camera asked for.
///
/// The input device runs at its own rate, usually 44100 or 48000 Hz, and can
/// change it under a running engine when the user switches device or a headset
/// connects. Both the tap format and the converter follow the hardware rather
/// than assuming one.
///
/// `@unchecked Sendable`: `AVAudioEngine`, `AVAudioConverter` and the stream
/// continuation are not `Sendable` and are touched from three threads — the
/// caller, the render thread that fires the tap, and whatever thread posts a
/// configuration change. Every one of them is reached only under `lock`, and
/// none of them escapes this object.
public final class MicrophoneSource: PCMSource, @unchecked Sendable {
    public let format: TalkAudioFormat

    private let lock = NSLock()
    private let tapBufferSize: AVAudioFrameCount
    private var engine: AVAudioEngine?
    private var converter: PCMConverter?
    private var continuation: AsyncThrowingStream<[Int16], Error>.Continuation?
    private var configurationObserver: NSObjectProtocol?

    public init(format: TalkAudioFormat = TalkAudioFormat(), tapBufferSize: AVAudioFrameCount = 4096) {
        self.format = format
        self.tapBufferSize = tapBufferSize
    }

    deinit { stop() }

    /// True when the machine has an audio input device.
    ///
    /// Asks the capture layer, not `AVAudioEngine`. Listing devices neither
    /// records nor raises the permission prompt; opening the engine's input node
    /// can do both.
    public static func hasInputDevice() -> Bool {
        AVCaptureDevice.default(for: .audio) != nil
    }

    /// Whether this process may record. `.notDetermined` means starting the
    /// engine will raise the system prompt.
    public static var authorization: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public func samples() -> AsyncThrowingStream<[Int16], Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] _ in self?.stop() }
            do {
                try start(yielding: continuation)
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    public func stop() {
        lock.lock()
        let engine = self.engine
        let continuation = self.continuation
        let observer = self.configurationObserver
        self.engine = nil
        self.converter = nil
        self.continuation = nil
        self.configurationObserver = nil
        lock.unlock()

        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        // Outside the lock: finish() runs the termination handler, which calls
        // back into stop().
        continuation?.finish()
    }

    private func start(yielding continuation: AsyncThrowingStream<[Int16], Error>.Continuation) throws {
        let engine = AVAudioEngine()
        guard engine.inputNode.inputFormat(forBus: 0).channelCount > 0 else {
            throw AudioSourceError.noInputDevice
        }
        let converter = try PCMConverter(target: format)

        lock.lock()
        self.engine = engine
        self.converter = converter
        self.continuation = continuation
        lock.unlock()

        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.reconfigure()
        }
        lock.lock()
        configurationObserver = observer
        lock.unlock()

        installTap(on: engine)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw AudioSourceError.engineFailed(String(describing: error))
        }
    }

    /// The tap takes the bus format as it stands, passing nil rather than a
    /// format of our own. A tap installed with a format the bus does not have
    /// traps inside AVAudioEngine, which is exactly what a mid-session rate
    /// change would cause.
    private func installTap(on engine: AVAudioEngine) {
        engine.inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: nil) { [weak self] buffer, _ in
            self?.receive(buffer)
        }
    }

    private func receive(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard let converter, let continuation else {
            lock.unlock()
            return
        }
        let result: Result<[Int16], Error>
        do {
            result = .success(try converter.convert(buffer))
        } catch {
            result = .failure(error)
        }
        lock.unlock()

        switch result {
        case .success(let samples):
            if !samples.isEmpty { continuation.yield(samples) }
        case .failure(let error):
            continuation.finish(throwing: error)
        }
    }

    /// The engine stops itself when the device changes rate or is swapped. Put
    /// the tap back against the new format and start again; the converter
    /// rebuilds itself when the next buffer arrives with a new format.
    private func reconfigure() {
        lock.lock()
        guard let engine, continuation != nil else {
            lock.unlock()
            return
        }
        lock.unlock()

        engine.inputNode.removeTap(onBus: 0)
        guard engine.inputNode.inputFormat(forBus: 0).channelCount > 0 else {
            finish(with: AudioSourceError.noInputDevice)
            return
        }
        installTap(on: engine)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            finish(with: AudioSourceError.engineFailed(String(describing: error)))
        }
    }

    private func finish(with error: Error) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish(throwing: error)
    }
}

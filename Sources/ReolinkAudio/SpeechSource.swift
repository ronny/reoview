import AVFoundation
import Foundation

/// Text spoken into the talk channel.
///
/// There is no way to upload a clip to the camera, so a generated reply has to
/// be spoken down the live channel like a person would. `AVSpeechSynthesizer`
/// writes PCM instead of playing it, and that PCM is resampled to the camera's
/// format here.
///
/// The synthesiser runs as fast as it can, so this source is not real time.
/// Pace the encoded blocks with ``AudioPacer`` on the way out.
///
/// `@unchecked Sendable`: `AVSpeechSynthesizer`, `AVAudioConverter` and the
/// stream continuation are not `Sendable`. The write callback arrives on a
/// private queue, so all three are reached only under `lock` and never escape.
public final class SpeechSource: PCMSource, @unchecked Sendable {
    public let format: TalkAudioFormat
    public let text: String

    private let voiceIdentifier: String?
    private let rate: Float?
    private let pitchMultiplier: Float?
    private let volume: Float?

    private let lock = NSLock()
    private var synthesizer: AVSpeechSynthesizer?
    private var converter: PCMConverter?
    private var continuation: AsyncThrowingStream<[Int16], Error>.Continuation?

    public init(
        text: String,
        format: TalkAudioFormat = TalkAudioFormat(),
        voiceIdentifier: String? = nil,
        rate: Float? = nil,
        pitchMultiplier: Float? = nil,
        volume: Float? = nil
    ) {
        self.text = text
        self.format = format
        self.voiceIdentifier = voiceIdentifier
        self.rate = rate
        self.pitchMultiplier = pitchMultiplier
        self.volume = volume
    }

    deinit { stop() }

    public func samples() -> AsyncThrowingStream<[Int16], Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] reason in
                if case .cancelled = reason { self?.stop() }
            }
            do {
                try start(yielding: continuation)
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    public func stop() {
        lock.lock()
        let synthesizer = self.synthesizer
        let continuation = self.continuation
        self.synthesizer = nil
        self.converter = nil
        self.continuation = nil
        lock.unlock()

        synthesizer?.stopSpeaking(at: .immediate)
        continuation?.finish()
    }

    private func start(yielding continuation: AsyncThrowingStream<[Int16], Error>.Continuation) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AudioSourceError.speechFailed("nothing to say")
        }
        let converter = try PCMConverter(target: format)
        let utterance = AVSpeechUtterance(string: text)
        if let voiceIdentifier {
            utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
                ?? AVSpeechSynthesisVoice(language: voiceIdentifier)
        }
        if let rate { utterance.rate = rate }
        if let pitchMultiplier { utterance.pitchMultiplier = pitchMultiplier }
        if let volume { utterance.volume = volume }

        let synthesizer = AVSpeechSynthesizer()
        lock.lock()
        self.synthesizer = synthesizer
        self.converter = converter
        self.continuation = continuation
        lock.unlock()

        synthesizer.write(utterance) { [weak self] buffer in
            self?.receive(buffer)
        }
    }

    private func receive(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else {
            finish(with: AudioSourceError.speechFailed("synthesiser returned \(type(of: buffer))"))
            return
        }
        // A zero-length buffer is how `write` says the utterance is done.
        guard pcm.frameLength > 0 else {
            finishAtEndOfSpeech()
            return
        }

        lock.lock()
        guard let converter, let continuation else {
            lock.unlock()
            return
        }
        let result = Result { try converter.convert(pcm) }
        lock.unlock()

        switch result {
        case .success(let samples):
            if !samples.isEmpty { continuation.yield(samples) }
        case .failure(let error):
            finish(with: error)
        }
    }

    private func finishAtEndOfSpeech() {
        lock.lock()
        let converter = self.converter
        let continuation = self.continuation
        self.converter = nil
        self.continuation = nil
        self.synthesizer = nil
        let tail = (try? converter?.drain()) ?? []
        lock.unlock()

        if !tail.isEmpty { continuation?.yield(tail) }
        continuation?.finish()
    }

    private func finish(with error: Error) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.converter = nil
        self.synthesizer = nil
        lock.unlock()
        continuation?.finish(throwing: error)
    }
}

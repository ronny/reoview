import AVFoundation
import Foundation

public enum AudioSourceError: Error, CustomStringConvertible {
    case unsupportedFormat(String)
    case noInputDevice
    case conversionFailed(String)
    case engineFailed(String)
    case speechFailed(String)

    public var description: String {
        switch self {
        case .unsupportedFormat(let why): "unsupported audio format: \(why)"
        case .noInputDevice: "no audio input device is available"
        case .conversionFailed(let why): "audio conversion failed: \(why)"
        case .engineFailed(let why): "audio engine failed: \(why)"
        case .speechFailed(let why): "speech synthesis failed: \(why)"
        }
    }
}

/// Turns whatever PCM a source hands over into the mono 16-bit stream the
/// camera asked for.
///
/// Deliberately not `Sendable`. `AVAudioConverter` is not thread safe and holds
/// resampler state, so each owner keeps one behind its own lock.
final class PCMConverter {
    let target: AVAudioFormat

    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    init(target format: TalkAudioFormat) throws {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(format.sampleRate),
            channels: AVAudioChannelCount(format.channels),
            interleaved: true
        ) else {
            throw AudioSourceError.unsupportedFormat("\(format.sampleRate) Hz, \(format.channels) channels")
        }
        self.target = target
    }

    /// The rate the last buffer arrived at, or nil before the first buffer.
    var currentSourceRate: Double? { sourceFormat?.sampleRate }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> [Int16] {
        guard buffer.frameLength > 0 else { return [] }
        let converter = try converter(for: buffer.format)
        let ratio = target.sampleRate / buffer.format.sampleRate
        // Slack covers the resampler filter's own latency on the first buffer.
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024

        // AVAudioConverter runs the input block synchronously on this thread
        // before `convert` returns, but types it as `@Sendable`. The box carries
        // the buffer and the once-only flag across that annotation; nothing here
        // is ever touched from a second thread.
        let supply = InputSupply(buffer: buffer)
        var samples: [Int16] = []
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                throw AudioSourceError.conversionFailed("could not allocate an output buffer")
            }
            var failure: NSError?
            let status = converter.convert(to: output, error: &failure) { _, inputStatus in
                if supply.consumed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supply.consumed = true
                inputStatus.pointee = .haveData
                return supply.buffer
            }
            if let failure { throw failure }
            samples.append(contentsOf: Self.int16Samples(of: output))
            guard status == .haveData, output.frameLength == capacity else { return samples }
        }
    }

    /// Pulls whatever the resampler still holds. Call once at the end of a
    /// source, or the tail of the last word is lost.
    func drain() throws -> [Int16] {
        guard let converter else { return [] }
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else { return [] }
        var failure: NSError?
        _ = converter.convert(to: output, error: &failure) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        if let failure, failure.code != kAudioConverterErr_UnspecifiedError { return [] }
        return Self.int16Samples(of: output)
    }

    /// Rebuilds when the source format changes. A Mac input device can change
    /// its rate under a running engine, so this is not a one-time setup.
    private func converter(for format: AVAudioFormat) throws -> AVAudioConverter {
        if let converter, let sourceFormat, sourceFormat == format { return converter }
        guard let made = AVAudioConverter(from: format, to: target) else {
            throw AudioSourceError.conversionFailed("no converter from \(format) to \(target)")
        }
        made.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        converter = made
        sourceFormat = format
        return made
    }

    private final class InputSupply: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var consumed = false

        init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }

    private static func int16Samples(of buffer: AVAudioPCMBuffer) -> [Int16] {
        guard buffer.frameLength > 0, let data = buffer.int16ChannelData else { return [] }
        let channels = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength) * channels))
    }
}

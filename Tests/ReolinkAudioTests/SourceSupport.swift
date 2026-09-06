import AVFoundation
import Foundation
@testable import ReolinkAudio

struct CollectionTimedOut: Error {}

/// Drains a source, or gives up. A source that never finishes would otherwise
/// hang the whole suite.
func collect(_ source: some PCMSource, timeout: Duration = .seconds(30)) async throws -> [Int16] {
    try await withThrowingTaskGroup(of: [Int16]?.self) { group in
        group.addTask {
            var all: [Int16] = []
            for try await chunk in source.samples() { all.append(contentsOf: chunk) }
            return all
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        let first = try await group.next() ?? nil
        group.cancelAll()
        source.stop()
        guard let samples = first else { throw CollectionTimedOut() }
        return samples
    }
}

/// A buffer of float PCM at whatever rate a Mac input device might hand over.
func makeFloatBuffer(sampleRate: Double, frames: AVAudioFrameCount, channels: AVAudioChannelCount = 1) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0 ..< Int(channels) {
        let data = buffer.floatChannelData![channel]
        for frame in 0 ..< Int(frames) {
            data[frame] = 0.5 * Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate))
        }
    }
    return buffer
}

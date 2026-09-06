import Foundation
@testable import ReolinkAudio

/// The encoder ffmpeg actually ships, rebuilt here so the reference blocks can
/// be reproduced bit for bit.
///
/// This is **not** the encoder this project ships, and the difference is
/// deliberate. ffmpeg quantises with a divide,
/// `min(7, |delta| * 4 / step)`, and reconstructs with
/// `step * difflookup[code] / 8`. An IMA decoder reconstructs with shifts,
/// `step/8 + step + step/2 + step/4` as the code selects, and the two do not
/// agree on every step value, so ffmpeg's own predictor drifts a little from
/// the one its decoder will follow.
///
/// That matters here more than it does in a WAV file. This format writes the
/// encoder's predictor into every block header, so a predictor that has drifted
/// would make the decoder jump at every block boundary — 15.6 times a second at
/// 1024 samples and 16000 Hz. `IMAADPCMEncoder` therefore reconstructs the way
/// the decoder does. `src/Neolink.Server/Media/Adpcm.cs` makes the same choice
/// and says so.
///
/// See `FFmpeg/libavcodec/adpcmenc.c`, `adpcm_ima_compress_sample`.
struct FFmpegIMAEncoder {
    private var predictor: Int32
    private var stepIndex: Int32 = 0

    init(predictor: Int32 = 0) {
        self.predictor = predictor
    }

    mutating func codes(for samples: [Int16]) -> [UInt8] {
        samples.map { compress($0) }
    }

    /// ffmpeg packs the earlier sample of a pair in the low nibble.
    static func pack(_ codes: [UInt8]) -> [UInt8] {
        stride(from: 0, to: codes.count, by: 2).map { codes[$0] | (codes[$0 + 1] << 4) }
    }

    private mutating func compress(_ sample: Int16) -> UInt8 {
        let step = ADPCMTables.step[Int(stepIndex)]
        let delta = Int32(sample) - predictor
        let magnitude = min(7, abs(delta) * 4 / step)
        let code = UInt8(magnitude) + (delta < 0 ? 8 : 0)

        // Swift and C both truncate integer division toward zero, so a negative
        // difflookup entry rounds the same way here as it does in ffmpeg.
        predictor += step * Self.difflookup[Int(code)] / 8
        predictor = min(max(predictor, -32768), 32767)
        stepIndex = min(max(stepIndex + ADPCMTables.index[Int(code)], 0), 88)
        return code
    }

    private static let difflookup: [Int32] = [
        1, 3, 5, 7, 9, 11, 13, 15,
        -1, -3, -5, -7, -9, -11, -13, -15,
    ]
}

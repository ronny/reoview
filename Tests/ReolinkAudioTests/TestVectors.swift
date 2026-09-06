import Foundation

/// The PCM the encoder tests run through, and ffmpeg's answer for it.
///
/// Both generators are deterministic, so the same samples can be piped to
/// ffmpeg and to the encoder with nothing to drift between them. See
/// ``ffmpegSquareReference`` for how the references were made.
enum TestVectors {
    /// A swept square wave with a sawtooth envelope and low-level noise.
    ///
    /// Integer only. The sweep and the envelope drag the step index over most of
    /// its range in both directions; the noise stops it settling. Amplitudes
    /// stay inside Int16 so nothing clips before the encoder sees it.
    static func square(count: Int) -> [Int16] {
        var out: [Int16] = []
        out.reserveCapacity(count)
        var random: UInt32 = 0x1234_5678
        var phase = 0
        for index in 0 ..< count {
            random = random &* 1_664_525 &+ 1_013_904_223
            let noise = Int32(bitPattern: random >> 16) % 401 - 200
            let period = 8 + (index / 64) % 56
            phase += 1
            if phase >= period { phase = 0 }
            let square: Int32 = phase * 2 < period ? 1 : -1
            let envelope = Int32(1000 + (index % 512) * 60)
            out.append(Int16(clamping: square * envelope + noise))
        }
        return out
    }

    /// Three tones under a slow envelope, at 16000 Hz. Smooth enough that ADPCM
    /// tracks it the way it tracks speech, so error bounds mean something.
    static func tone(count: Int) -> [Int16] {
        (0 ..< count).map { index in
            let time = Double(index) / 16_000
            let envelope = 0.35 + 0.3 * sin(2 * .pi * 3 * time)
            let value = envelope * (
                9_000 * sin(2 * .pi * 220 * time)
                    + 4_500 * sin(2 * .pi * 760 * time)
                    + 2_000 * sin(2 * .pi * 2_300 * time)
            )
            return Int16(clamping: Int(value.rounded()))
        }
    }

    /// One 1024-byte IMA WAV block from ffmpeg 9.0.1, holding 2041 samples: a
    /// leading zero, then `square(count: 2040)`.
    ///
    /// The leading zero is what lines the two encoders up. ffmpeg puts the first
    /// sample of a block in the DVI state header and codes only the rest, so
    /// seeding it with 0 matches this encoder's own starting predictor of 0 and
    /// step index of 0.
    ///
    /// Regenerate with:
    ///
    ///     ffmpeg -f s16le -ar 16000 -ac 1 -i vector.raw \
    ///            -c:a adpcm_ima_wav -block_size 1024 -f wav reference.wav
    ///
    /// then take the `data` chunk.
    static let ffmpegSquareReference = decode(ffmpegSquareReferenceBase64)

    /// The same, for `tone(count: 2040)`.
    static let ffmpegToneReference = decode(ffmpegToneReferenceBase64)

    private static func decode(_ base64: String) -> [UInt8] {
        Array(Data(base64Encoded: base64, options: .ignoreUnknownCharacters)!)
    }

    static let ffmpegSquareReferenceBase64 = """
    AAAAAHf3/3oE8AlogNAIWIDQCFiA0AhYgNAIWAjQgFgI0IBACAiNgAUI2AhYgICNAAQI6IBYgIANCAQI6IBAgIAOCIQA6ICA
    hYDQgIAFCNgICAUI6ICAhQDYgICFANgICAUI2AgIeAgIyAgIhoCAjYBgCAjYgIAFCAiOgFAICOAICAUICI6AgAYICA8ICAYI
    iI4AiAcICI+AgAcICI+AgAcICI+AgHCAAAifgIAHgIDwCQh4gQiAn4CAFwiI8AkIeIGAgJ8ICHgBgICfCAh4AQiAn4iAcIKA
    gK+AgHCCgICvgIBwgoCA8AsICCeAgIC/gIBwAoCA8IuAgDcICAi/CAh4AwiNgICAgBiACICwgICAYICAAPgJCAh4gQAI+AmI
    gHCBAAgIr4CACCcICAj4CoiAcIIACAi/gICAJwAICPgLCAh4g4CAgL+ACAh4hICAgK+AgIBwAggICL+AgIBwg4CAgL8ICAgI
    R4CAgIC/gAgIeISAgIDwC4AICDcICAgIz4CAgIAnAAgICM+AgICAJ4CAAAi/CAiIgEeAgIAAvwgICAhHCAgICPiLgICAcAQI
    CAgIz4AICAg3CAgICPiMgICAcIMACIgA3wiACIB4gwAICAjfgICAgHCDAIgACN8ICIAIeISAgICA8A0ICAgIRwgICAiA34CA
    gAhwhAAICAj4jYCAhoAACAgICAiYCAiIgAh4gYAACAj4iwgIiIBwB4CAgACI34CACICIVwgIgICA8A2IgICAcAQICAgICO8I
    gIAICHgECAgICAjvgIAIgAh4BAgICAgI3wgIiACIcAUICIgACPgOCAgIiIBHCICAgICA74AIgAgIeAQICAgICPiOAIiAgIBw
    hYCAAAiI8I2AgICAgHCGgICAgIDwjICAgICAeIeAgAAICAjfgICAgICAVwgICAiAgPgOCAgICIhwBAgIgAiAgP8ICAgIiIBw
    hgAICAiIAP+AgICAgIBwBggICAgIgPiPCAgIgAiAd4CAgICAgAD/CQgICAiIcAeAgICAgJ+ACAgICAgIiDCAAIgAgICA8Y8I
    CIiAgIB4FwiIAAiAgAD/iYAICAiIgHcBCAgIgIAA+K+AgICAgJBwF4CAgIAACID/iYCACAgICHgXgAAICAgICP+JCAgIgAgI
    eBeAAIgACAgI+K+AgIAICAgId4KAgIAACAgI/4oICAiACAh4J4CAgICAAAj4v4CAgICAgIB4N4CAgACIAAj4z4CAgICAgAiA
    dwKAgICAgICA8M+AgAgICIAIeCcICICACAiAgP8LiAAIiICAgHBHgICAgICAgID/CwgICIiAgIBwR4CAgICAgICA8M+AgICA
    gAgICHcCCAgIgICAgID/jA==
    """

    static let ffmpegToneReferenceBase64 = """
    AAAAAHB3d3cCqoohoIl0EqgJAPutiJCqKTSQmyDQzooRmBlGI4AwFLmdIYOJciaBCCGovoqAygpTgroYoe+qCKiqUTORGDSw
    rykRqFA3EggyA+uaEaibcxSYGRH6vImoywk0gJoyou+ZAagKVBQAMCSoqyCCu3EnAQgikb6akNqLQQKqKIPuqwm5rDA1kSA1
    kbwZA8o5ZxIYQRK5mxDJrFAjmBkk6L2JqbwLM5KKc4LrmgHJmnMTAUEkkZsgkcxIRIEAU4HbiojMmyGCqUgj7JwJubwpJQA4
    RQG6GALaGlUSEFMjuJsB2a0oI6gpNsC9iri+iyGBilQDyosB6ZtRIwFiNIGaEaLMGTWBGEUCu5uY3qsQgZpIJMmsCcm9GTKR
    MEcSqRAC6gpSAxBzI5iZEdmtGQKoKUWQvIq4z5oQgIlSFKmJEdmdIDMAYiaCiCCR6wkigRlVA7mKkO27CIC6SDSonQjIzYkS
    gCk3E4goE9qMQRIIcySRCRHIvQoBuRpFkrsKuP+aAJiJQRSQCSLIrhAiiGE1A4gig9yKIZCKVROoCoH8rImQuiglkash0L6L
    EaAZVyKIISPJnCECmXMmgYgSoL6KgLqLRYK6GZHvqgiYm1AkkBgzsK8YEahQRgKAMgLLmxG4nHMjqBki+6+ImLoZM5KLUZHP
    mQGoilUjAEAzuJwgkqtxJgEII6HdioDLmkKCmiiD7qsJqa0wNIAgNZG8GRLKSUYTAFISuZsQya0xJZgZJNm9iqjMCjKRiVKD
    3JoQyZpzIwBBNJCbIJG8SDaCEGOB24qY26shAqowFuu7CcmtGCQAOEUBuhgCyytWEhBSI7iaEOmsKCOoKDXAvpm4zYoRgQpi
    A7qMEMqdQRQBQTWRmRGRzCk0ARhFg8qLmPyqAAGaOCXJrAi5rxkigDhGAqgoAtuKRBMYcxSQiQDIvBkSqSk2ob2KyN2aEJGJ
    UiO5iiL6nCAUgVI1goggkr0bM5IZVxK5ipD8uwiRqjgmsLsA6L0KEoA5VwKQEBLJjEECCHMUkYgRyMwJELkZRJLLCajPmxiY
    mmIjoBki2L0QFIhRNgKIMYLMCyGQilUUmQqB+62IkKooJJGrIdDOChCYGUYjiCEUyJsxAplzJwCIErDNiYC5C2OCuhih35sI
    qKtRJJEYM8G9GCKpYDYTAEED25oRqJxTJKgZEvu9iaC7GkSRijGi34oBqApkE4ExJairIZKrcTaBGDKhv4qIy5tSgqkoAu6r
    CKmsMCWBKESRrBkCuTl3AgAxE8mLEMmcQCOYKSTpvZmozAoygYpiguuKALmLcyQAQTOhmyCRvUg2ghhEgbybkM2bIIOqQCPs
    rIi4vSgkgThFgqoZAtoaVQ==
    """
}

import Foundation
@testable import ReolinkAudio

/// An IMA/DVI-4 decoder written for the tests only.
///
/// Deliberately written from the textbook form rather than from the encoder, so
/// a round trip proves something. It re-seeds from every block's DVI state
/// header, which is what the camera is expected to do.
struct ADPCMDecoder {
    var samplesPerBlock: Int
    var nibbleOrder: ADPCMNibbleOrder

    private(set) var predictor: Int32 = 0
    private(set) var stepIndex: Int32 = 0

    init(samplesPerBlock: Int = 1024, nibbleOrder: ADPCMNibbleOrder = .lowNibbleFirst) {
        self.samplesPerBlock = samplesPerBlock
        self.nibbleOrder = nibbleOrder
    }

    /// Decodes one block, seeding the state from its 4-byte header.
    mutating func decode(block: Data) -> [Int16] {
        let bytes = Array(block)
        precondition(bytes.count >= 4)
        predictor = Int32(Int16(bitPattern: UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)))
        stepIndex = Int32(bytes[2])

        var out: [Int16] = []
        out.reserveCapacity((bytes.count - 4) * 2)
        for byte in bytes[4...] {
            let low = byte & 0x0f
            let high = byte >> 4
            let pair = nibbleOrder == .lowNibbleFirst ? [low, high] : [high, low]
            for code in pair { out.append(expand(code)) }
        }
        return out
    }

    mutating func decode(blocks: [Data]) -> [Int16] {
        blocks.flatMap { decode(block: $0) }
    }

    private mutating func expand(_ code: UInt8) -> Int16 {
        let step = ADPCMTables.step[Int(stepIndex)]
        var difference = step >> 3
        if code & 4 != 0 { difference += step }
        if code & 2 != 0 { difference += step >> 1 }
        if code & 1 != 0 { difference += step >> 2 }
        predictor += (code & 8) != 0 ? -difference : difference
        predictor = min(max(predictor, -32768), 32767)
        stepIndex = min(max(stepIndex + ADPCMTables.index[Int(code & 0x0f)], 0), 88)
        return Int16(predictor)
    }
}

enum ADPCMTables {
    static let index: [Int32] = [
        -1, -1, -1, -1, 2, 4, 6, 8,
        -1, -1, -1, -1, 2, 4, 6, 8,
    ]

    static let step: [Int32] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
        19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
        50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
        130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
        337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
        876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
        2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
        5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
        15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
    ]
}

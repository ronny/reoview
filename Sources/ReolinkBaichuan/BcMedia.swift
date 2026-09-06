import Foundation

/// Which serializer to copy for the two BcMedia fields that the working
/// implementations disagree on.
///
/// Both rules come from code that drives real cameras, and they differ by four
/// bytes per frame. `neolinkRust` is the default because it is the serializer
/// inside `QuantumEntangledAndy/neolink`, the only complete talk implementation
/// read that is known to make cameras speak.
public enum BcMediaFrameRules: Sendable, Equatable, CaseIterable {
    /// `crates/core/src/bcmedia/ser.rs`. Half block is `(len - 4) / 2`, and the
    /// pad is measured from the block length itself.
    case neolinkRust
    /// `src/Neolink.Server/Media/Adpcm.cs` in `borexola/neolink.net`. Half block
    /// is `len / 2`, and the pad is measured from the block length plus the
    /// four header bytes, which for a 516-byte block means no padding at all.
    case neolinkDotNet
}

/// The BcMedia container the talk payload is wrapped in.
public enum BcMedia {
    /// `30 31 77 62` on the wire, ASCII "01wb".
    public static let adpcmMagic: UInt32 = 0x6277_3130
    /// The sub-magic at offset 8.
    public static let adpcmSubMagic: UInt16 = 0x0100
    /// Bytes in front of the block: magic, two lengths, sub-magic, half block.
    public static let adpcmHeaderLength = 12
    /// Media packets pad out to an 8-byte boundary.
    public static let padSize = 8
    /// `i16 le predictor`, `u8 step index`, `u8 reserved`, in front of every
    /// block, because each block re-seeds the decoder from its own state.
    public static let dviStateLength = 4

    /// Bytes of packed nibbles in one block, from `lengthPerEncoder`.
    ///
    /// `lengthPerEncoder` counts samples, and ADPCM packs two samples per byte.
    public static func blockSize(lengthPerEncoder: Int) -> Int { lengthPerEncoder / 2 }

    /// What one complete block on the wire measures: the packed nibbles plus
    /// the DVI state header. 516 bytes for `lengthPerEncoder` 1024.
    public static func fullBlockSize(lengthPerEncoder: Int) -> Int {
        blockSize(lengthPerEncoder: lengthPerEncoder) + dviStateLength
    }

    /// Wraps one ADPCM block, DVI state header included, in a BcMedia frame.
    public static func adpcmFrame(block: Data, rules: BcMediaFrameRules = .neolinkRust) -> Data {
        let length = block.count
        var frame = Data(capacity: adpcmHeaderLength + length + padSize)
        frame.appendLittleEndian(adpcmMagic)
        // Repeated deliberately. Both fields carry the same number on the wire.
        frame.appendLittleEndian(UInt16(truncatingIfNeeded: length + 4))
        frame.appendLittleEndian(UInt16(truncatingIfNeeded: length + 4))
        frame.appendLittleEndian(adpcmSubMagic)
        frame.appendLittleEndian(UInt16(truncatingIfNeeded: halfBlockSize(blockLength: length, rules: rules)))
        frame.append(block)
        frame.append(Data(count: paddingLength(blockLength: length, rules: rules)))
        return frame
    }

    /// The field at offset 10.
    ///
    /// neolink's own parser says of it: "On some camera this value is just 2.
    /// On other cameras is half the block size without the header." The device
    /// very likely ignores it.
    public static func halfBlockSize(blockLength: Int, rules: BcMediaFrameRules) -> Int {
        switch rules {
        case .neolinkRust: max(0, blockLength - dviStateLength) / 2
        case .neolinkDotNet: blockLength / 2
        }
    }

    /// Zero bytes appended after the block.
    ///
    /// This is the riskier of the two disputed fields, because it changes how
    /// many bytes the device has to skip before the next frame.
    public static func paddingLength(blockLength: Int, rules: BcMediaFrameRules) -> Int {
        let base: Int = switch rules {
        case .neolinkRust: blockLength
        case .neolinkDotNet: blockLength + dviStateLength
        }
        let remainder = base % padSize
        return remainder == 0 ? 0 : padSize - remainder
    }
}

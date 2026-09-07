import Foundation

/// Which serializer to copy for the two BcMedia fields that the working
/// implementations disagree on.
///
/// This NVR ignores both fields. The doorbell spoke with `neolinkRust`, whose
/// frame is four bytes longer and carries 256 where Reolink's own app sends 2.
/// `reolinkApp` is the default anyway, because matching the vendor's client
/// byte for byte is the safer bet on firmware nobody here has seen.
///
/// What did matter, and is not configurable: the binary payload goes in the
/// clear, and message 202 carries message number 0.
public enum BcMediaFrameRules: Sendable, Equatable, CaseIterable {
    /// `crates/core/src/bcmedia/ser.rs`. Half block is `(len - 4) / 2`, and the
    /// pad is measured from the block length itself.
    case neolinkRust
    /// `src/Neolink.Server/Media/Adpcm.cs` in `borexola/neolink.net`. Half block
    /// is `len / 2`, and the pad is measured from the block length plus the
    /// four header bytes, which for a 516-byte block means no padding at all.
    case neolinkDotNet

    /// What Reolink's own macOS app sends to this NVR, captured from the wire
    /// on 2026-09-07: the field at offset 10 is 2, and there is no padding.
    /// neolink's parser predicts this case — "on some camera this value is just
    /// 2" — but neither implementation defaults to it.
    case reolinkApp
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
    public static func adpcmFrame(block: Data, rules: BcMediaFrameRules = .reolinkApp) -> Data {
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
        case .reolinkApp: 2
        }
    }

    /// Zero bytes appended after the block.
    ///
    /// This is the riskier of the two disputed fields, because it changes how
    /// many bytes the device has to skip before the next frame.
    public static func paddingLength(blockLength: Int, rules: BcMediaFrameRules) -> Int {
        if case .reolinkApp = rules { return 0 }
        let base: Int = switch rules {
        case .neolinkRust: blockLength
        case .neolinkDotNet: blockLength + dviStateLength
        case .reolinkApp: 0
        }
        let remainder = base % padSize
        return remainder == 0 ? 0 : padSize - remainder
    }
}

import Foundation
import Testing
@testable import ReolinkBaichuan

@Suite("BcMedia framing")
struct BcMediaTests {
    /// 512 bytes of packed nibbles behind the 4-byte DVI state header, which is
    /// what `lengthPerEncoder` 1024 asks for.
    private let block = Data([0x34, 0x12, 0x07, 0x00]) + Data(repeating: 0x5A, count: 512)

    /// The first 12 bytes Reolink's own macOS app put on the wire for a 516-byte
    /// block, captured on 2026-09-07: "01wb", 520, 520, 0x0100, then 2.
    private let capturedHeader = Data([0x30, 0x31, 0x77, 0x62, 0x08, 0x02, 0x08, 0x02, 0x00, 0x01, 0x02, 0x00])

    @Test("The frame starts with 01wb and repeats the length twice")
    func layout() {
        let frame = BcMedia.adpcmFrame(block: block)
        #expect(frame.prefix(4) == Data([0x30, 0x31, 0x77, 0x62]))
        #expect(frame.readLittleEndian(at: 4) as UInt16 == 520)
        #expect(frame.readLittleEndian(at: 6) as UInt16 == 520)
        #expect(frame.readLittleEndian(at: 8) as UInt16 == 0x0100)
        #expect(frame.dropFirst(12).prefix(4) == Data([0x34, 0x12, 0x07, 0x00]))
    }

    /// Guards the bug that made the doorbell silent: any return of padding, or
    /// of a half-block field computed from the block length, breaks this.
    @Test("The default frame is byte identical to the header Reolink's app sent")
    func matchesCapturedHeader() {
        let frame = BcMedia.adpcmFrame(block: block)
        #expect(frame.prefix(12) == capturedHeader)
        #expect(frame.count == 528)
        #expect(frame.dropFirst(12) == block)
    }

    @Test("Reolink's own rules are the default: half block 2, no padding")
    func reolinkAppRules() {
        let frame = BcMedia.adpcmFrame(block: block)
        #expect(frame.readLittleEndian(at: 10) as UInt16 == 2)
        #expect(frame.count == 12 + 516)
        #expect(frame.suffix(4) == Data(repeating: 0x5A, count: 4))
    }

    @Test("The Rust serializer's rules: half block 256, 4 pad bytes")
    func neolinkRustRules() {
        let frame = BcMedia.adpcmFrame(block: block, rules: .neolinkRust)
        #expect(frame.readLittleEndian(at: 10) as UInt16 == 256)
        #expect(frame.count == 12 + 516 + 4)
        #expect(frame.suffix(4) == Data(repeating: 0, count: 4))
    }

    @Test("The .NET rules differ by four bytes and two counts")
    func neolinkDotNetRules() {
        let frame = BcMedia.adpcmFrame(block: block, rules: .neolinkDotNet)
        #expect(frame.readLittleEndian(at: 10) as UInt16 == 258)
        #expect(frame.count == 12 + 516)
    }

    @Test("The three rules disagree only in the ways the research and the capture recorded")
    func rulesDiffer() {
        #expect(BcMedia.halfBlockSize(blockLength: 516, rules: .neolinkRust) == 256)
        #expect(BcMedia.halfBlockSize(blockLength: 516, rules: .neolinkDotNet) == 258)
        #expect(BcMedia.halfBlockSize(blockLength: 516, rules: .reolinkApp) == 2)
        #expect(BcMedia.paddingLength(blockLength: 516, rules: .neolinkRust) == 4)
        #expect(BcMedia.paddingLength(blockLength: 516, rules: .neolinkDotNet) == 0)
        #expect(BcMedia.paddingLength(blockLength: 516, rules: .reolinkApp) == 0)
    }

    @Test("The default rules never pad, whatever the block length")
    func defaultRulesNeverPad() {
        for length in 8...40 {
            let frame = BcMedia.adpcmFrame(block: Data(repeating: 0, count: length))
            #expect(frame.count == BcMedia.adpcmHeaderLength + length)
            #expect(frame.readLittleEndian(at: 10) as UInt16 == 2)
        }
    }

    @Test("The Rust rules end every frame on an 8-byte boundary")
    func neolinkRustPadsToBoundary() {
        for length in 8...40 {
            let frame = BcMedia.adpcmFrame(block: Data(repeating: 0, count: length), rules: .neolinkRust)
            #expect((frame.count - BcMedia.adpcmHeaderLength) % BcMedia.padSize == 0)
        }
    }

    @Test("Block sizes come from lengthPerEncoder")
    func blockSizes() {
        #expect(BcMedia.blockSize(lengthPerEncoder: 1024) == 512)
        #expect(BcMedia.fullBlockSize(lengthPerEncoder: 1024) == 516)
    }
}

import Foundation
import Testing
@testable import ReolinkBaichuan

@Suite("BcMedia framing")
struct BcMediaTests {
    /// 512 bytes of packed nibbles behind the 4-byte DVI state header, which is
    /// what `lengthPerEncoder` 1024 asks for.
    private let block = Data([0x34, 0x12, 0x07, 0x00]) + Data(repeating: 0x5A, count: 512)

    @Test("The frame starts with 01wb and repeats the length twice")
    func layout() {
        let frame = BcMedia.adpcmFrame(block: block)
        #expect(frame.prefix(4) == Data([0x30, 0x31, 0x77, 0x62]))
        #expect(frame.readLittleEndian(at: 4) as UInt16 == 520)
        #expect(frame.readLittleEndian(at: 6) as UInt16 == 520)
        #expect(frame.readLittleEndian(at: 8) as UInt16 == 0x0100)
        #expect(frame.dropFirst(12).prefix(4) == Data([0x34, 0x12, 0x07, 0x00]))
    }

    @Test("The Rust serializer's rules are the default: half block 256, 4 pad bytes")
    func neolinkRustRules() {
        let frame = BcMedia.adpcmFrame(block: block)
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

    @Test("The two rules disagree only in the ways the research recorded")
    func rulesDiffer() {
        #expect(BcMedia.halfBlockSize(blockLength: 516, rules: .neolinkRust) == 256)
        #expect(BcMedia.halfBlockSize(blockLength: 516, rules: .neolinkDotNet) == 258)
        #expect(BcMedia.paddingLength(blockLength: 516, rules: .neolinkRust) == 4)
        #expect(BcMedia.paddingLength(blockLength: 516, rules: .neolinkDotNet) == 0)
    }

    @Test("Every frame ends on an 8-byte boundary under the default rules")
    func padsToBoundary() {
        for length in 8...40 {
            let frame = BcMedia.adpcmFrame(block: Data(repeating: 0, count: length))
            #expect((frame.count - BcMedia.adpcmHeaderLength) % BcMedia.padSize == 0)
        }
    }

    @Test("Block sizes come from lengthPerEncoder")
    func blockSizes() {
        #expect(BcMedia.blockSize(lengthPerEncoder: 1024) == 512)
        #expect(BcMedia.fullBlockSize(lengthPerEncoder: 1024) == 516)
    }
}

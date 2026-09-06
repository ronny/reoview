import Foundation
import Testing
@testable import ReolinkBaichuan

@Suite("Header codec")
struct HeaderCodecTests {
    @Test("A 24-byte header round trips through encode and parse")
    func modernRoundTrip() throws {
        let header = BcHeader(
            messageID: 202,
            bodyLength: 4296,
            channelID: 1,
            messageNumber: 6,
            status: 0,
            messageClass: BcMessageClass.modernWithPayloadOffset,
            payloadOffset: 136
        )
        let bytes = header.encoded()
        #expect(bytes.count == 24)
        #expect(try BcHeader(parsing: bytes) == header)
    }

    @Test("A 20-byte header carries no payload offset in either direction")
    func legacyRoundTrip() throws {
        let header = BcHeader(
            messageID: 1,
            channelID: BcChannelID.host,
            messageNumber: 1,
            status: BcEncryptionLevel.fullAes.requestWord,
            messageClass: BcMessageClass.legacy
        )
        let bytes = header.encoded()
        #expect(bytes.count == 20)
        #expect(header.payloadOffset == nil)
        #expect(try BcHeader(parsing: bytes) == header)
    }

    @Test("The nonce request is the byte sequence the device answers")
    func nonceRequestBytes() {
        let header = BcHeader(
            messageID: BcMessageID.login,
            channelID: BcChannelID.host,
            messageNumber: 1,
            status: BcEncryptionLevel.fullAes.requestWord,
            messageClass: BcMessageClass.legacy
        )
        #expect(header.encoded().hexString == "f0debc0a0100000000000000fa01000012dc1465")
    }

    @Test("The recorded nonce reply header parses")
    func nonceReply() throws {
        let header = try BcHeader(parsing: Data(hex: Fixture.nonceReplyHeader))
        #expect(header.messageID == BcMessageID.login)
        #expect(header.bodyLength == 311)
        #expect(header.channelID == BcChannelID.host)
        #expect(header.messageNumber == 1)
        #expect(header.messageClass == BcMessageClass.modern)
        #expect(header.length == 20)
        #expect(header.payloadOffset == nil)
        // 0x12dd is a cipher, not a status: FullAes with the nonce body still
        // under BCEncrypt.
        #expect(BcEncryptionLevel(replyWord: header.status) == .fullAes)
    }

    @Test("The recorded message 199 reply carries status 300")
    func supportReply() throws {
        let header = try BcHeader(parsing: Data(hex: Fixture.supportReplyHeader))
        #expect(header.messageID == BcMessageID.support)
        #expect(header.status == 300)
        #expect(header.messageClass == BcMessageClass.modernZero)
        #expect(header.length == 24)
        // A zero payload offset means the whole body is the XML region.
        #expect(header.payloadOffset == 0)
        #expect(header.extensionLength == Int(header.bodyLength))
    }

    @Test("The recorded talk push splits the body into extension and payload")
    func talkPush() throws {
        let header = try BcHeader(parsing: Data(hex: Fixture.talkPushHeader))
        #expect(header.messageID == BcMessageID.talk)
        #expect(header.bodyLength == 4296)
        #expect(header.extensionLength == 136)
        #expect(Int(header.bodyLength) - header.extensionLength == 4160)
        // Header byte 12 is the only place the channel appears on a 202.
        #expect(header.channelID == 1)
    }

    @Test("Bytes 12 to 15 read back as one correlation word")
    func correlation() throws {
        let header = try BcHeader(parsing: Data(hex: Fixture.nonceReplyHeader))
        #expect(header.correlationID == 506)
        #expect(header.encryptionOffset == 250)
    }

    @Test("An unknown message class is refused rather than guessed at")
    func unknownClass() {
        var bytes = Data(hex: Fixture.loginReplyHeader)
        bytes[18] = 0x99
        bytes[19] = 0x99
        #expect(throws: BaichuanError.self) { try BcHeader(parsing: bytes) }
    }

    @Test("Bad magic is refused")
    func badMagic() {
        var bytes = Data(hex: Fixture.loginReplyHeader)
        bytes[0] = 0x00
        #expect(throws: BaichuanError.self) { try BcHeader(parsing: bytes) }
    }

    @Test("A channel becomes ch_id, and the host keeps its own number")
    func channelIDs() {
        #expect(BcChannelID.forChannel(0) == 1)
        #expect(BcChannelID.forChannel(7) == 8)
        #expect(BcChannelID.forChannel(nil) == BcChannelID.host)
    }
}

@Suite("Frame reassembly")
struct FrameReaderTests {
    private func frame(id: UInt32, extensionText: String, payload: Data) -> BcFrame {
        let ext = Data(extensionText.utf8)
        return BcFrame(
            header: BcHeader(
                messageID: id,
                bodyLength: UInt32(ext.count + payload.count),
                channelID: 1,
                messageNumber: 6,
                payloadOffset: UInt32(ext.count)
            ),
            extensionBytes: ext,
            payloadBytes: payload
        )
    }

    @Test("A frame split across reads is not yielded until it is complete")
    func splitAcrossReads() throws {
        let original = frame(id: 202, extensionText: "<Extension/>", payload: Data(repeating: 0xAB, count: 40))
        let bytes = original.encoded()

        var reader = BcFrameReader()
        reader.append(bytes.prefix(10))
        #expect(try reader.next() == nil)
        reader.append(bytes.dropFirst(10).prefix(20))
        #expect(try reader.next() == nil)
        reader.append(bytes.dropFirst(30))
        #expect(try reader.next() == original)
        #expect(try reader.next() == nil)
    }

    @Test("Several frames in one read all come back, in order")
    func manyInOneRead() throws {
        let first = frame(id: 10, extensionText: "<a/>", payload: Data())
        let second = frame(id: 202, extensionText: "<b/>", payload: Data(repeating: 1, count: 8))
        var reader = BcFrameReader()
        reader.append(first.encoded() + second.encoded())
        #expect(try reader.next() == first)
        #expect(try reader.next() == second)
        #expect(try reader.next() == nil)
        #expect(reader.bufferedByteCount == 0)
    }

    @Test("A body with no payload offset lands entirely in the extension region")
    func zeroOffsetIsAllXML() throws {
        let body = Data("<?xml version=\"1.0\" ?><body/>".utf8)
        let header = BcHeader(
            messageID: 199,
            bodyLength: UInt32(body.count),
            channelID: BcChannelID.host,
            messageNumber: 4,
            status: 300,
            messageClass: BcMessageClass.modernZero,
            payloadOffset: 0
        )
        var reader = BcFrameReader()
        reader.append(header.encoded() + body)
        let frame = try #require(try reader.next())
        #expect(frame.extensionBytes == body)
        #expect(frame.payloadBytes.isEmpty)
    }
}

@Suite("Status classification")
struct StatusTests {
    @Test("200, 201 and 300 are all successes", arguments: [200, 201, 300])
    func successes(_ status: Int) {
        #expect(BcStatus.isSuccess(status))
    }

    @Test("Everything else is a failure", arguments: [0, 100, 199, 202, 299, 301, 400, 401, 422, 500])
    func failures(_ status: Int) {
        #expect(!BcStatus.isSuccess(status))
    }

    @Test("The numeric status survives into the error")
    func statusSurvives() {
        let error = BaichuanError.status(messageID: 201, status: 422)
        #expect(error.status == 422)
        #expect(error.isTalkSlotBusy)
        #expect(!error.isUnauthorized)
        #expect(BaichuanError.status(messageID: 1, status: 401).isUnauthorized)
    }
}

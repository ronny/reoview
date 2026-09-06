import Foundation
@testable import ReolinkBaichuan

/// Stands in for the NVR on port 9000.
///
/// It answers with the shapes recorded off the real device: FullAes only, the
/// nonce body under BCEncrypt, status 300 for message 199, an empty 200 for
/// message 201, and no reply at all to message 202.
actor FakeDevice: BaichuanConnection {
    /// Statuses to hand out, in order, for one message id. The queue is used up
    /// first and the default takes over afterwards.
    var statusQueue: [UInt32: [UInt16]] = [:]
    /// Message ids the device will not answer.
    var silentMessageIDs: Set<UInt32> = [BcMessageID.talk]
    /// The word the device claims in its nonce reply.
    var encryptionLevel: BcEncryptionLevel = .fullAes

    private(set) var received: [BcFrame] = []
    private(set) var isOpen = false

    private var reader = BcFrameReader()
    private var inbox: [Data] = []
    private var waiter: CheckedContinuation<Data, any Error>?

    let key = BcCrypto.aesKey(nonce: Fixture.nonce, password: Fixture.password)

    func open() async throws { isOpen = true }

    func close() async {
        isOpen = false
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: Data())
        }
    }

    func send(_ data: Data) async throws {
        reader.append(data)
        while let frame = try reader.next() {
            received.append(frame)
            if let reply = answer(to: frame) {
                deliver(reply)
            }
        }
    }

    func receive() async throws -> Data {
        if !inbox.isEmpty { return inbox.removeFirst() }
        if !isOpen { return Data() }
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
        }
    }

    // MARK: - Test helpers

    func frames(messageID: UInt32) -> [BcFrame] {
        received.filter { $0.header.messageID == messageID }
    }

    /// Reads a body the client sent under AES.
    func decryptAES(_ data: Data) throws -> Data {
        try BcCrypto.aesCFB(data, key: key, encrypt: false)
    }

    /// Reads a body the client sent under BCEncrypt.
    func decryptBC(_ data: Data, offset: UInt32) -> Data {
        BcCrypto.bcEncrypt(data, offset: offset)
    }

    /// Pushes bytes at the client without being asked, the way the NVR pushes
    /// message 202 once talk is open.
    func push(_ data: Data) {
        deliver(data)
    }

    // MARK: - Answers

    private func nextStatus(for messageID: UInt32, default fallback: UInt16) -> UInt16 {
        guard var queued = statusQueue[messageID], !queued.isEmpty else { return fallback }
        let status = queued.removeFirst()
        statusQueue[messageID] = queued
        return status
    }

    private func answer(to frame: BcFrame) -> Data? {
        let header = frame.header
        guard !silentMessageIDs.contains(header.messageID) else { return nil }

        switch header.messageID {
        case BcMessageID.login where header.messageClass == BcMessageClass.legacy:
            // The nonce reply is a 20-byte modern header whose encryption word
            // names the cipher for the session, while the body itself is still
            // BCEncrypt.
            let body = BcCrypto.bcEncrypt(Data(Fixture.encryption.utf8), offset: header.encryptionOffset)
            return BcFrame(
                header: BcHeader(
                    messageID: header.messageID,
                    bodyLength: UInt32(body.count),
                    channelID: header.channelID,
                    messageNumber: header.messageNumber,
                    status: encryptionLevel.replyWord,
                    messageClass: BcMessageClass.modern
                ),
                extensionBytes: body
            ).encoded()

        case BcMessageID.login:
            let status = nextStatus(for: header.messageID, default: 200)
            let body = status == 200
                ? BcCrypto.bcEncrypt(Data(Fixture.support.utf8), offset: header.encryptionOffset)
                : Data()
            return modernReply(to: header, status: status, body: body)

        case BcMessageID.support:
            let status = nextStatus(for: header.messageID, default: 300)
            return modernReply(to: header, status: status, body: aes(Fixture.support))

        case BcMessageID.talkAbility:
            let status = nextStatus(for: header.messageID, default: 200)
            return modernReply(
                to: header,
                status: status,
                body: status == 200 ? aes(Fixture.talkAbilityOnWire) : Data()
            )

        case BcMessageID.talkConfig, BcMessageID.talkReset, BcMessageID.linkType, BcMessageID.logout:
            // Message 201 answers 200 with an empty body.
            return modernReply(to: header, status: nextStatus(for: header.messageID, default: 200), body: Data())

        default:
            return modernReply(to: header, status: 200, body: Data())
        }
    }

    private func aes(_ text: String) -> Data {
        (try? BcCrypto.aesCFB(Data(text.utf8), key: key, encrypt: true)) ?? Data()
    }

    private func modernReply(to header: BcHeader, status: UInt16, body: Data) -> Data {
        BcFrame(
            header: BcHeader(
                messageID: header.messageID,
                bodyLength: UInt32(body.count),
                channelID: header.channelID,
                messageNumber: header.messageNumber,
                status: status,
                messageClass: BcMessageClass.modernZero,
                payloadOffset: 0
            ),
            extensionBytes: body
        ).encoded()
    }

    private func deliver(_ data: Data) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
        } else {
            inbox.append(data)
        }
    }
}

extension FakeDevice {
    func setStatusQueue(_ queue: [UInt32: [UInt16]]) { statusQueue = queue }
    func setSilent(_ ids: Set<UInt32>) { silentMessageIDs = ids }
    func setEncryptionLevel(_ level: BcEncryptionLevel) { encryptionLevel = level }
}

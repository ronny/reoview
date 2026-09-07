import Foundation
import Testing
@testable import ReolinkBaichuan

private let credentials = BaichuanCredentials(user: Fixture.user, password: Fixture.password)

private func makeClient(
    _ device: FakeDevice,
    configuration: BaichuanClient.Configuration = BaichuanClient.Configuration(requestTimeout: .seconds(2))
) -> BaichuanClient {
    BaichuanClient(connection: device, credentials: credentials, configuration: configuration)
}

@Suite("Login")
struct LoginTests {
    @Test("The handshake asks for FullAes and nothing weaker")
    func asksForFullAes() async throws {
        let device = FakeDevice()
        let client = makeClient(device)
        try await client.connect()

        let logins = await device.frames(messageID: BcMessageID.login)
        #expect(logins.count == 2)
        let nonceRequest = try #require(logins.first)
        #expect(nonceRequest.header.messageClass == BcMessageClass.legacy)
        #expect(nonceRequest.header.status == 0xdc12)
        #expect(nonceRequest.header.bodyLength == 0)
        #expect(nonceRequest.header.channelID == BcChannelID.host)
        await client.disconnect()
    }

    @Test("The modern login goes out under BCEncrypt with 31-character hashes")
    func modernLoginBody() async throws {
        let device = FakeDevice()
        let client = makeClient(device)
        try await client.connect()

        let login = try #require(await device.frames(messageID: BcMessageID.login).last)
        #expect(login.header.messageClass == BcMessageClass.modernWithPayloadOffset)
        #expect(login.header.payloadOffset == 0)

        let plain = await device.decryptBC(login.extensionBytes, offset: login.header.encryptionOffset)
        let body = try #require(String(data: plain, encoding: .utf8))
        #expect(body.contains("<userName>3F4E4E7C4418492BA1A48B19839F18A</userName>"))
        #expect(body.contains("<password>849DAD014F63DF8B57130885C8044A8</password>"))
        #expect(body.contains("<type>LAN</type>"))
        #expect(await client.isLoggedIn)
        await client.disconnect()
    }

    @Test("Bad credentials surface as status 401")
    func badCredentials() async throws {
        let device = FakeDevice()
        await device.setStatusQueue([BcMessageID.login: [401]])
        let client = makeClient(device)

        await #expect(throws: BaichuanError.self) { try await client.connect() }
        #expect(await !client.isLoggedIn)
    }

    @Test("A device that will not do AES is refused rather than downgraded to")
    func refusesWeakCipher() async throws {
        let device = FakeDevice()
        await device.setEncryptionLevel(.bcEncrypt)
        let client = makeClient(device)

        await #expect(throws: BaichuanError.self) { try await client.connect() }
    }

    @Test("A silent device times out with the message id kept")
    func timeout() async throws {
        let device = FakeDevice()
        await device.setSilent([BcMessageID.login])
        let client = makeClient(device, configuration: .init(requestTimeout: .milliseconds(80)))

        do {
            try await client.connect()
            Issue.record("expected a timeout")
        } catch let error as BaichuanError {
            guard case let .timeout(messageID) = error else {
                Issue.record("expected a timeout, got \(error)")
                return
            }
            #expect(messageID == BcMessageID.login)
        }
    }
}

@Suite("Commands")
struct CommandTests {
    @Test("Message 199 is accepted at status 300")
    func deviceInfoAcceptsThreeHundred() async throws {
        let device = FakeDevice()
        let client = makeClient(device)
        try await client.connect()

        let info = try await client.deviceInfo()
        #expect(info.supportsTalk(channel: 0))
        #expect(!info.supportsTalk(channel: 2))

        let request = try #require(await device.frames(messageID: BcMessageID.support).first)
        #expect(request.header.channelID == BcChannelID.host)
        await client.disconnect()
    }

    @Test("Message 10 is addressed by channel and returns the device's ability")
    func talkAbility() async throws {
        let device = FakeDevice()
        let client = makeClient(device)
        try await client.connect()

        let ability = try await client.talkAbility(channel: 0)
        #expect(ability.audioType == "adpcm")
        #expect(ability.lengthPerEncoder == 1024)

        let request = try #require(await device.frames(messageID: BcMessageID.talkAbility).first)
        #expect(request.header.channelID == 1)
        let extensionXML = try await String(decoding: device.decryptAES(request.extensionBytes), as: UTF8.self)
        #expect(extensionXML.contains("<channelId>0</channelId>"))
        await client.disconnect()
    }

    @Test("A channel with no camera answers 400 and the number survives")
    func emptyChannel() async throws {
        let device = FakeDevice()
        await device.setStatusQueue([BcMessageID.talkAbility: [400]])
        let client = makeClient(device)
        try await client.connect()

        do {
            _ = try await client.talkAbility(channel: 5)
            Issue.record("expected a 400")
        } catch let error as BaichuanError {
            #expect(error.status == 400)
        }
        await client.disconnect()
    }
}

@Suite("Talk")
struct TalkTests {
    /// The first 12 bytes of the message 202 payload Reolink's own macOS app
    /// put on the wire for a 516-byte block: "01wb", 520, 520, 0x0100, then 2.
    private let capturedTalkHeader = Data([
        0x30, 0x31, 0x77, 0x62, 0x08, 0x02, 0x08, 0x02, 0x00, 0x01, 0x02, 0x00,
    ])

    private func connectedClient(
        _ device: FakeDevice,
        rules: BcMediaFrameRules = .reolinkApp
    ) async throws -> BaichuanClient {
        let client = BaichuanClient(
            connection: device,
            credentials: credentials,
            configuration: .init(requestTimeout: .seconds(2), frameRules: rules)
        )
        try await client.connect()
        return client
    }

    @Test("Message 201 carries the config built from the device's own ability")
    func startTalkBody() async throws {
        let device = FakeDevice()
        let client = try await connectedClient(device)
        let ability = try await client.talkAbility(channel: 0)
        _ = try await client.startTalk(channel: 0, ability: ability)

        let request = try #require(await device.frames(messageID: BcMessageID.talkConfig).first)
        #expect(request.header.channelID == 1)
        // The channel extension and the TalkConfig are ciphered separately and
        // then concatenated, so the config lives in the payload region.
        let extensionXML = try await String(decoding: device.decryptAES(request.extensionBytes), as: UTF8.self)
        #expect(extensionXML.contains("<channelId>0</channelId>"))
        let body = try await String(decoding: device.decryptAES(request.payloadBytes), as: UTF8.self)
        #expect(body.contains("<TalkConfig version=\"1.1\">"))
        #expect(body.contains("<audioStreamMode>mixAudioStream</audioStreamMode>"))
        #expect(body.contains("<lengthPerEncoder>1024</lengthPerEncoder>"))
        await client.disconnect()
    }

    @Test("A 422 releases the slot and retries once")
    func retriesOnBusy() async throws {
        let device = FakeDevice()
        await device.setStatusQueue([BcMessageID.talkConfig: [422, 200]])
        let client = try await connectedClient(device)
        let ability = try await client.talkAbility(channel: 0)

        _ = try await client.startTalk(channel: 0, ability: ability)

        #expect(await device.frames(messageID: BcMessageID.talkConfig).count == 2)
        // Message 11 goes out between the two attempts.
        #expect(await device.frames(messageID: BcMessageID.talkReset).count >= 1)
        await client.disconnect()
    }

    @Test("A device that offers something other than adpcm is refused")
    func refusesNonADPCM() async throws {
        let device = FakeDevice()
        let client = try await connectedClient(device)
        var ability = try await client.talkAbility(channel: 0)
        ability.audioType = "aac"

        await #expect(throws: BaichuanError.self) {
            _ = try await client.startTalk(channel: 0, ability: ability)
        }
        await client.disconnect()
    }

    /// The one that matters on the wire: the message 202 frame, end to end,
    /// through the fake connection. Every value here comes from a capture of
    /// Reolink's own macOS app talking to this NVR on 2026-09-07.
    @Test("Message 202 sends a plaintext BcMedia frame, no encryptLen, message number 0")
    func sendBlock() async throws {
        let device = FakeDevice()
        let client = try await connectedClient(device)
        let ability = try await client.talkAbility(channel: 0)
        let session = try await client.startTalk(channel: 0, ability: ability)

        #expect(session.format == TalkAudioFormat(
            sampleRate: 16000, samplePrecision: 16, channels: 1, samplesPerBlock: 1024
        ))

        let block = Data([0x34, 0x12, 0x07, 0x00]) + Data(repeating: 0x5A, count: 512)
        try await session.send(block: block)

        let sent = try #require(await device.frames(messageID: BcMessageID.talk).first)

        // Header: channel in byte 12, one message number for the whole stream,
        // and both length fields counted from the bytes actually written.
        #expect(sent.header.channelID == 1)
        #expect(sent.header.messageClass == BcMessageClass.modernWithPayloadOffset)
        #expect(sent.header.payloadOffset == UInt32(sent.extensionBytes.count))
        #expect(sent.header.bodyLength == UInt32(sent.extensionBytes.count + sent.payloadBytes.count))

        // Extension.
        let extensionXML = try await String(decoding: device.decryptAES(sent.extensionBytes), as: UTF8.self)
        #expect(extensionXML.contains("<binaryData>1</binaryData>"))
        #expect(extensionXML.contains("<channelId>0</channelId>"))
        // The session negotiated FullAes, and the NVR still encrypts the 202
        // frames it pushes at us, but nothing outbound declares a length.
        #expect(!extensionXML.contains("encryptLen"))

        // The message number is 0 on every outbound 202, not the number the
        // talk session was opened with.
        #expect(sent.header.messageNumber == 0)

        // The payload is plaintext, not ciphertext. Encrypting it is accepted
        // without error by the device, which then plays nothing.
        #expect(sent.payloadBytes.count == 528)
        #expect(sent.payloadBytes.prefix(12) == capturedTalkHeader)
        #expect(sent.payloadBytes.readLittleEndian(at: 4) as UInt16 == 520)
        #expect(sent.payloadBytes.readLittleEndian(at: 6) as UInt16 == 520)
        #expect(sent.payloadBytes.readLittleEndian(at: 8) as UInt16 == 0x0100)
        #expect(sent.payloadBytes.readLittleEndian(at: 10) as UInt16 == 2)
        #expect(sent.payloadBytes.dropFirst(12) == block)

        await session.stop()
        await client.disconnect()
    }

    @Test(
        "The frame rules set the payload length, and none of them declares encryptLen",
        arguments: [
            (BcMediaFrameRules.reolinkApp, 528, UInt16(2)),
            (BcMediaFrameRules.neolinkRust, 532, UInt16(256)),
            (BcMediaFrameRules.neolinkDotNet, 528, UInt16(258)),
        ]
    )
    func frameRulesSetPayloadLength(rules: BcMediaFrameRules, length: Int, halfBlock: UInt16) async throws {
        let device = FakeDevice()
        let client = try await connectedClient(device, rules: rules)
        let ability = try await client.talkAbility(channel: 0)
        let session = try await client.startTalk(channel: 0, ability: ability)

        try await session.send(block: Data(repeating: 0x11, count: 516))
        let sent = try #require(await device.frames(messageID: BcMessageID.talk).first)
        let extensionXML = try await String(decoding: device.decryptAES(sent.extensionBytes), as: UTF8.self)
        #expect(!extensionXML.contains("encryptLen"))
        #expect(sent.payloadBytes.count == length)
        #expect(sent.payloadBytes.prefix(4) == Data([0x30, 0x31, 0x77, 0x62]))
        #expect(sent.payloadBytes.readLittleEndian(at: 10) as UInt16 == halfBlock)
        await client.disconnect()
    }

    @Test("Every message 202 carries message number 0, not the one talk was opened with")
    func everyTalkMessageNumberIsZero() async throws {
        let device = FakeDevice()
        let client = try await connectedClient(device)
        let ability = try await client.talkAbility(channel: 0)
        let session = try await client.startTalk(channel: 0, ability: ability)

        let block = Data(repeating: 0x22, count: 516)
        for _ in 0..<3 { try await session.send(block: block) }

        let numbers = await Set(device.frames(messageID: BcMessageID.talk).map(\.header.messageNumber))
        #expect(numbers == [0])
        // Message 201 still gets a real number, so the 0 above is a deliberate
        // choice rather than an unopened session leaking through.
        let configNumber = try #require(await device.frames(messageID: BcMessageID.talkConfig).first?.header.messageNumber)
        #expect(configNumber != 0)
        await client.disconnect()
    }

    @Test("A block the device did not ask for is refused before it reaches the wire")
    func rejectsWrongBlockSize() async throws {
        let device = FakeDevice()
        let client = try await connectedClient(device)
        let ability = try await client.talkAbility(channel: 0)
        let session = try await client.startTalk(channel: 0, ability: ability)

        await #expect(throws: BaichuanError.self) {
            try await session.send(block: Data(repeating: 0, count: 1024))
        }
        #expect(await device.frames(messageID: BcMessageID.talk).isEmpty)
        await client.disconnect()
    }

    @Test("Sending with no open session is refused")
    func refusesWithoutSession() async throws {
        let device = FakeDevice()
        let client = try await connectedClient(device)
        await #expect(throws: BaichuanError.self) {
            try await client.send(block: Data(repeating: 0, count: 516), channel: 0)
        }
        await client.disconnect()
    }

    @Test("Stop sends message 11 and is safe to call twice")
    func stopIsIdempotent() async throws {
        let device = FakeDevice()
        let client = try await connectedClient(device)
        let ability = try await client.talkAbility(channel: 0)
        let session = try await client.startTalk(channel: 0, ability: ability)

        await session.stop()
        await session.stop()

        let resets = await device.frames(messageID: BcMessageID.talkReset)
        #expect(resets.count == 2)
        #expect(resets.allSatisfy { $0.header.channelID == 1 })
        await client.disconnect()
    }

    @Test("An unsolicited message 202 push is dropped, not mistaken for a reply")
    func ignoresPushes() async throws {
        let device = FakeDevice()
        let client = try await connectedClient(device)

        let push = BcFrame(
            header: BcHeader(
                messageID: BcMessageID.talk,
                bodyLength: 4,
                channelID: 1,
                messageNumber: 99,
                status: 200,
                messageClass: BcMessageClass.modernZero,
                payloadOffset: 0
            ),
            extensionBytes: Data([1, 2, 3, 4])
        )
        await device.push(push.encoded())

        // The connection still works afterwards.
        let ability = try await client.talkAbility(channel: 0)
        #expect(ability.audioType == "adpcm")
        await client.disconnect()
    }
}

import Foundation
import Testing
@testable import ReolinkBaichuan

@Suite("Bodies")
struct XMLTests {
    @Test("The device's own TalkAbility parses, verbatim")
    func talkAbilityVerbatim() throws {
        let ability = try BcXML.talkAbility(from: Fixture.talkAbility)
        #expect(ability.duplexes == ["FDX"])
        #expect(ability.audioStreamModes == ["followVideoStream", "mixAudioStream"])
        #expect(ability.audioType == "adpcm")
        #expect(ability.sampleRate == 16000)
        #expect(ability.samplePrecision == 16)
        #expect(ability.lengthPerEncoder == 1024)
        #expect(ability.soundTrack == "mono")
    }

    @Test("The same ability parses inside the declaration and body wrapper")
    func talkAbilityOnWire() throws {
        #expect(try BcXML.talkAbility(from: Fixture.talkAbilityOnWire)
            == BcXML.talkAbility(from: Fixture.talkAbility))
    }

    @Test("mixAudioStream is preferred, because it is the mode that opens the return path")
    func preferredMode() throws {
        let ability = try BcXML.talkAbility(from: Fixture.talkAbility)
        #expect(ability.preferredAudioStreamMode == "mixAudioStream")
        #expect(ability.preferredDuplex == "FDX")
        #expect(ability.isTalkable)
    }

    @Test("The audio format follows lengthPerEncoder, not an assumption")
    func audioFormat() throws {
        let ability = try BcXML.talkAbility(from: Fixture.talkAbility)
        #expect(ability.audioFormat == TalkAudioFormat(
            sampleRate: 16000, samplePrecision: 16, channels: 1, samplesPerBlock: 1024
        ))
        // 1024 samples is 512 bytes of nibbles plus the 4-byte DVI state.
        #expect(ability.fullBlockSize == 516)
    }

    @Test("A TalkAbility with no audioConfig is a decode failure, not a default")
    func abilityWithoutConfig() {
        #expect(throws: BaichuanError.self) {
            try BcXML.talkAbility(from: "<TalkAbility version=\"1.1\"><duplexList/></TalkAbility>")
        }
    }

    @Test("The TalkConfig body is the one the device answered 200 to")
    func talkConfigBody() throws {
        let ability = try BcXML.talkAbility(from: Fixture.talkAbility)
        let body = BcXML.talkConfig(channel: 0, ability: ability, mode: ability.preferredAudioStreamMode)
        #expect(body == """
            <?xml version="1.0" encoding="UTF-8" ?>
            <body>
            <TalkConfig version="1.1">
            <channelId>0</channelId>
            <duplex>FDX</duplex>
            <audioStreamMode>mixAudioStream</audioStreamMode>
            <audioConfig>
            <audioType>adpcm</audioType>
            <sampleRate>16000</sampleRate>
            <samplePrecision>16</samplePrecision>
            <lengthPerEncoder>1024</lengthPerEncoder>
            <soundTrack>mono</soundTrack>
            </audioConfig>
            </TalkConfig>
            </body>

            """)
    }

    @Test("The TalkConfig copies the channel and the ability it was given")
    func talkConfigCarriesChannel() throws {
        let ability = try BcXML.talkAbility(from: Fixture.talkAbility)
        let body = BcXML.talkConfig(channel: 3, ability: ability, mode: "followVideoStream")
        #expect(body.contains("<channelId>3</channelId>"))
        #expect(body.contains("<audioStreamMode>followVideoStream</audioStreamMode>"))
    }

    @Test("The talk extension declares binary mode, the channel and encryptLen")
    func talkExtension() {
        #expect(BcXML.talkExtension(channel: 0, encryptLen: 532) == """
            <?xml version="1.0" encoding="UTF-8" ?>
            <Extension version="1.1">
            <binaryData>1</binaryData>
            <channelId>0</channelId>
            <encryptLen>532</encryptLen>
            </Extension>

            """)
    }

    @Test("Without FullAes the extension carries no encryptLen")
    func talkExtensionWithoutEncryption() {
        let body = BcXML.talkExtension(channel: 0, encryptLen: nil)
        #expect(!body.contains("encryptLen"))
        #expect(body.contains("<binaryData>1</binaryData>"))
    }

    @Test("Message 199 reports ipcAudioTalk per channel")
    func supportBody() throws {
        let info = try BcXML.deviceInfo(from: Fixture.support)
        #expect(info.channelCount == 12)
        #expect(info.channels.count == 3)
        #expect(info.supportsTalk(channel: 0))
        #expect(info.supportsTalk(channel: 1))
        #expect(!info.supportsTalk(channel: 2))
        // An absent channel is not a talkable one.
        #expect(!info.supportsTalk(channel: 9))
        #expect(info.channels.first?.channelType == "Doorbell")
    }

    @Test("The nonce is read out of the login reply")
    func nonce() throws {
        #expect(try BcXML.nonce(from: Fixture.encryption) == Fixture.nonce)
    }

    @Test("A body that is not XML is a decode failure")
    func garbage() {
        #expect(throws: BaichuanError.self) { try BcXML.nonce(from: "not xml at all") }
        #expect(throws: BaichuanError.self) { try BcXML.deviceInfo(from: "") }
    }
}

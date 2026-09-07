import Foundation

/// Bytes and bodies recorded off the RLN8-410 at 192.0.2.10:9000,
/// firmware v3.6.5.562, on 2026-09-06. No audio was ever sent to it.
enum Fixture {
    /// The nonce reply. 20-byte header, class `14 66`, and the two bytes at
    /// offset 16 are the encryption word `12 dd`, not a status.
    static let nonceReplyHeader = "f0debc0a0100000037010000fa01000012dd1466"

    /// The reply to the modern login. Class `00 00`, status 200, no extension.
    static let loginReplyHeader = "f0debc0a01000000c70a0000fa020000c800000000000000"

    /// The reply to message 199, status `2c 01`, which is 300 and a success.
    static let supportReplyHeader = "f0debc0ac70000005f370000010400002c01000000000000"

    /// One inbound message 202 push. Body 4296 bytes, of which 136 are the
    /// extension and 4160 the encrypted audio payload.
    static let talkPushHeader = "f0debc0aca000000c810000001060000c800000088000000"

    /// Verbatim from docs/research/baichuan-talk.md. Channel 0 and channel 1
    /// return byte-identical XML.
    static let talkAbility = """
        <TalkAbility version="1.1">
        <duplexList><duplex>FDX</duplex></duplexList>
        <audioStreamModeList>
        <audioStreamMode>followVideoStream</audioStreamMode>
        <audioStreamMode>mixAudioStream</audioStreamMode>
        </audioStreamModeList>
        <audioConfigList><audioConfig>
        <priority>0</priority>
        <audioType>adpcm</audioType>
        <sampleRate>16000</sampleRate>
        <samplePrecision>16</samplePrecision>
        <lengthPerEncoder>1024</lengthPerEncoder>
        <soundTrack>mono</soundTrack>
        </audioConfig></audioConfigList>
        </TalkAbility>
        """

    /// The same ability as it arrives on the wire, inside the declaration and
    /// the `<body>` wrapper the device adds.
    static let talkAbilityOnWire = """
        <?xml version="1.0" encoding="UTF-8" ?>
        <body>
        \(talkAbility)
        </body>

        """

    /// A cut-down message 199 reply. The shape is the device's: global fields,
    /// then one `<item>` per channel. There is no `audioTalk` element.
    static let support = """
        <?xml version="1.0" encoding="UTF-8" ?>
        <body>
        <Support version="1.1">
        <channelNum>12</channelNum>
        <audioNum>16</audioNum>
        <item>
        <chnID>0</chnID>
        <audioVersion>11231</audioVersion>
        <ipcAudioTalk>1</ipcAudioTalk>
        <channelType>Doorbell</channelType>
        </item>
        <item>
        <chnID>1</chnID>
        <ipcAudioTalk>1</ipcAudioTalk>
        <channelType>IPC</channelType>
        </item>
        <item>
        <chnID>2</chnID>
        <ipcAudioTalk>0</ipcAudioTalk>
        </item>
        </Support>
        </body>

        """

    static let nonce = "ABCDEF0123456789"
    static let user = "admin"
    static let password = "s3cr3t"

    static let encryption = """
        <?xml version="1.0" encoding="UTF-8" ?>
        <body>
        <Encryption version="1.1">
        <type>md5</type>
        <nonce>\(nonce)</nonce>
        </Encryption>
        </body>

        """
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

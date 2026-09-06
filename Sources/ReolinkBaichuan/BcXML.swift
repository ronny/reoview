import Foundation

/// The message ids this client uses.
public enum BcMessageID {
    public static let login: UInt32 = 1
    public static let logout: UInt32 = 2
    public static let talkAbility: UInt32 = 10
    public static let talkReset: UInt32 = 11
    public static let linkType: UInt32 = 93
    public static let support: UInt32 = 199
    public static let talkConfig: UInt32 = 201
    public static let talk: UInt32 = 202
    public static let udpKeepalive: UInt32 = 234
}

/// What message 199 reports about talk.
///
/// There is no `audioTalk` element on firmware v3.6.5.562. Only `ipcAudioTalk`,
/// one per `<item>`, keyed by `chnID`. Code that looks for `audioTalk` finds
/// nothing and concludes, wrongly, that the NVR cannot talk.
public struct BaichuanDeviceInfo: Sendable, Equatable {
    public struct ChannelSupport: Sendable, Equatable {
        public var channel: Int
        public var ipcAudioTalk: Bool
        public var channelType: String?

        public init(channel: Int, ipcAudioTalk: Bool, channelType: String? = nil) {
            self.channel = channel
            self.ipcAudioTalk = ipcAudioTalk
            self.channelType = channelType
        }
    }

    public var channelCount: Int?
    public var channels: [ChannelSupport]

    public init(channelCount: Int? = nil, channels: [ChannelSupport]) {
        self.channelCount = channelCount
        self.channels = channels
    }

    public func supportsTalk(channel: Int) -> Bool {
        channels.first { $0.channel == channel }?.ipcAudioTalk ?? false
    }
}

/// Builds the request bodies and reads the replies.
///
/// Every template below is byte-for-byte what was sent to the RLN8-410 on
/// 2026-09-06, because the firmware answers 400 to shapes it does not like and
/// there is no rule for which shapes those are.
enum BcXML {
    static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n"

    static func channelExtension(_ channel: Int) -> String {
        """
        \(declaration)<Extension version="1.1">
        <channelId>\(channel)</channelId>
        </Extension>

        """
    }

    /// The extension on every message 202.
    ///
    /// `binaryData` 1 puts this message number into binary mode: the receiver
    /// treats the payload of every later message with the same number as bytes
    /// rather than XML, until it sees a 0.
    ///
    /// `encryptLen` is the FullAes addition. It says how many payload bytes are
    /// AES-encrypted, counted from the front. Element order follows neolink's
    /// own `Extension` struct so the device sees the field order it emits.
    static func talkExtension(channel: Int, encryptLen: Int?) -> String {
        var body = """
            \(declaration)<Extension version="1.1">
            <binaryData>1</binaryData>
            <channelId>\(channel)</channelId>

            """
        if let encryptLen {
            body += "<encryptLen>\(encryptLen)</encryptLen>\n"
        }
        return body + "</Extension>\n"
    }

    static func login(userHash: String, passwordHash: String) -> String {
        """
        \(declaration)<body>
        <LoginUser version="1.1">
        <userName>\(userHash)</userName>
        <password>\(passwordHash)</password>
        <userVer>1</userVer>
        </LoginUser>
        <LoginNet version="1.1">
        <type>LAN</type>
        <udpPort>0</udpPort>
        </LoginNet>
        </body>

        """
    }

    static func logout(userHash: String, passwordHash: String) -> String {
        """
        \(declaration)<body>
        <LoginUser version="1.1">
        <userName>\(userHash)</userName>
        <password>\(passwordHash)</password>
        <userVer>1</userVer>
        </LoginUser>
        </body>

        """
    }

    static func talkConfig(channel: Int, ability: TalkAbility, mode: String) -> String {
        """
        \(declaration)<body>
        <TalkConfig version="1.1">
        <channelId>\(channel)</channelId>
        <duplex>\(ability.preferredDuplex)</duplex>
        <audioStreamMode>\(mode)</audioStreamMode>
        <audioConfig>
        <audioType>\(ability.audioType)</audioType>
        <sampleRate>\(ability.sampleRate)</sampleRate>
        <samplePrecision>\(ability.samplePrecision)</samplePrecision>
        <lengthPerEncoder>\(ability.lengthPerEncoder)</lengthPerEncoder>
        <soundTrack>\(ability.soundTrack)</soundTrack>
        </audioConfig>
        </TalkConfig>
        </body>

        """
    }

    static func document(_ xml: String) throws -> XMLDocument {
        let trimmed = xml.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
        guard !trimmed.isEmpty else {
            throw BaichuanError.decode(detail: "empty body")
        }
        do {
            return try XMLDocument(xmlString: trimmed, options: [.nodePreserveWhitespace])
        } catch {
            throw BaichuanError.decode(detail: "not XML: \(error.localizedDescription)")
        }
    }

    static func nonce(from xml: String) throws -> String {
        let value = try first(text: "//nonce", in: document(xml))
        guard let value, !value.isEmpty else {
            throw BaichuanError.decode(detail: "the login reply carried no nonce")
        }
        return value
    }

    static func talkAbility(from xml: String) throws -> TalkAbility {
        let document = try document(xml)
        guard let config = try document.nodes(forXPath: "//audioConfigList/audioConfig").first else {
            throw BaichuanError.decode(detail: "TalkAbility carried no audioConfig")
        }
        let duplexes = try texts("//duplexList/duplex", in: document)
        let modes = try texts("//audioStreamModeList/audioStreamMode", in: document)
        guard let audioType = try first(text: "audioType", in: config) else {
            throw BaichuanError.decode(detail: "audioConfig carried no audioType")
        }
        return TalkAbility(
            duplexes: duplexes,
            audioStreamModes: modes,
            audioType: audioType,
            sampleRate: try integer("sampleRate", in: config),
            samplePrecision: try integer("samplePrecision", in: config),
            soundTrack: try first(text: "soundTrack", in: config) ?? "mono",
            lengthPerEncoder: try integer("lengthPerEncoder", in: config)
        )
    }

    static func deviceInfo(from xml: String) throws -> BaichuanDeviceInfo {
        let document = try document(xml)
        var channels: [BaichuanDeviceInfo.ChannelSupport] = []
        for item in try document.nodes(forXPath: "//Support/item") {
            guard let id = try first(text: "chnID", in: item), let channel = Int(id) else { continue }
            let talk = try first(text: "ipcAudioTalk", in: item).flatMap(Int.init) ?? 0
            channels.append(
                BaichuanDeviceInfo.ChannelSupport(
                    channel: channel,
                    ipcAudioTalk: talk > 0,
                    channelType: try first(text: "channelType", in: item)
                )
            )
        }
        guard !channels.isEmpty else {
            throw BaichuanError.decode(detail: "the Support body carried no channel items")
        }
        return BaichuanDeviceInfo(
            channelCount: try first(text: "//Support/channelNum", in: document).flatMap(Int.init),
            channels: channels
        )
    }

    private static func first(text xpath: String, in node: XMLNode) throws -> String? {
        do {
            return try node.nodes(forXPath: xpath).first?.stringValue
        } catch {
            throw BaichuanError.decode(detail: "bad xpath \(xpath)")
        }
    }

    private static func texts(_ xpath: String, in node: XMLNode) throws -> [String] {
        do {
            return try node.nodes(forXPath: xpath).compactMap(\.stringValue)
        } catch {
            throw BaichuanError.decode(detail: "bad xpath \(xpath)")
        }
    }

    private static func integer(_ xpath: String, in node: XMLNode) throws -> Int {
        guard let text = try first(text: xpath, in: node), let value = Int(text) else {
            throw BaichuanError.decode(detail: "\(xpath) is missing or not a number")
        }
        return value
    }
}

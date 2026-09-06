import Foundation

public struct GetAbility: NVRCommand {
    public static let cmd = "GetAbility"

    public struct Param: Encodable, Sendable {
        let user: User

        struct User: Encodable, Sendable {
            let userName: String
        }

        enum CodingKeys: String, CodingKey {
            case user = "User"
        }
    }

    public struct Response: Decodable, Sendable {
        public let capabilities: Capabilities

        public init(from decoder: any Decoder) throws {
            capabilities = try ResponseValue(from: decoder).decodeUnwrapping(Capabilities.self, "Ability")
        }
    }

    public let param: Param

    public init(userName: String) {
        param = Param(user: .init(userName: userName))
    }
}

public struct GetChannelstatus: NVRCommand {
    public static let cmd = "GetChannelstatus"

    public struct Status: Decodable, Sendable, Hashable {
        public let channel: Int
        public let online: Int
        public let name: String?
        public let typeInfo: String?
        public let uid: String?
        public let sleep: Int?

        public var isOnline: Bool { online == 1 }
    }

    public struct Response: Decodable, Sendable {
        public let count: Int
        public let status: [Status]

        public init(from decoder: any Decoder) throws {
            let value = try ResponseValue(from: decoder)
            count = try value.decode(Int.self, "count")
            status = try value.decode([Status].self, "status")
        }
    }

    public let param = NoParam()

    public init() {}
}

public struct GetDevInfo: NVRCommand {
    public static let cmd = "GetDevInfo"

    public struct DevInfo: Decodable, Sendable, Hashable {
        public let name: String
        public let model: String
        public let serial: String
        public let hardVer: String
        public let firmVer: String
        public let channelNum: Int
        public let itemNo: String?
        public let type: String?
        public let exactType: String?
    }

    public struct Response: Decodable, Sendable {
        public let devInfo: DevInfo

        public init(from decoder: any Decoder) throws {
            devInfo = try ResponseValue(from: decoder).decodeUnwrapping(DevInfo.self, "DevInfo")
        }
    }

    public let param = NoParam()

    public init() {}
}

/// The video codec of one stream. `GetEnc` reports it as `vType`.
public enum VideoCodec: String, Sendable, Hashable, Codable {
    case h264
    case h265

    /// The other codec, which is the second URL candidate in `StreamResolver`.
    public var flipped: VideoCodec { self == .h264 ? .h265 : .h264 }
}

public struct GetEnc: NVRCommand {
    public static let cmd = "GetEnc"

    public struct Stream: Decodable, Sendable, Hashable {
        public let vType: String?
        public let width: Int?
        public let height: Int?
        public let bitRate: Int?
        public let frameRate: Int?

        public var codec: VideoCodec? { vType.flatMap(VideoCodec.init(rawValue:)) }
    }

    public struct Enc: Decodable, Sendable, Hashable {
        public let channel: Int?
        public let audio: Int?
        public let mainStream: Stream?
        public let subStream: Stream?
    }

    public struct Response: Decodable, Sendable {
        public let enc: Enc

        public init(from decoder: any Decoder) throws {
            enc = try ResponseValue(from: decoder).decodeUnwrapping(Enc.self, "Enc")
        }

        public func stream(_ quality: Quality) -> Stream? {
            switch quality {
            case .main: enc.mainStream
            case .sub: enc.subStream
            }
        }

        /// The codec to try first, with the fallback that `reolink_aio` uses
        /// when `GetEnc` comes back incomplete.
        public func codec(_ quality: Quality, mainEncTypeVersion: Int = 0) -> VideoCodec {
            if let codec = stream(quality)?.codec { return codec }
            if quality == .sub { return .h264 }
            return mainEncTypeVersion > 0 ? .h265 : .h264
        }
    }

    public let param = NoParam()

    public init() {}
}

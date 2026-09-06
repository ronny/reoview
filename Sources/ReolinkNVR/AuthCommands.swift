import Foundation

public struct Login: NVRCommand {
    public static let cmd = "Login"

    public struct Param: Encodable, Sendable {
        let user: User

        struct User: Encodable, Sendable {
            let version = "0"
            let userName: String
            let password: String

            enum CodingKeys: String, CodingKey {
                case version = "Version"
                case userName
                case password
            }
        }

        enum CodingKeys: String, CodingKey {
            case user = "User"
        }
    }

    public struct Response: Decodable, Sendable {
        public let token: String
        public let leaseTime: TimeInterval

        public init(from decoder: any Decoder) throws {
            let value = try ResponseValue(from: decoder)
            let token = try value.decodeUnwrapping(Token.self, "Token")
            self.token = token.name
            leaseTime = token.leaseTime ?? 0
        }

        private struct Token: Decodable, Sendable {
            let name: String
            let leaseTime: TimeInterval?
        }
    }

    public let param: Param

    public init(credentials: Credentials) {
        param = Param(user: .init(userName: credentials.user, password: credentials.password))
    }
}

public struct Logout: NVRCommand {
    public static let cmd = "Logout"

    /// The NVR answers `Logout` with a bare `rspCode`, and some firmwares with
    /// no `value` at all.
    public struct Response: Decodable, Sendable {
        public init(from decoder: any Decoder) throws {}
    }

    public let param = NoParam()

    public init() {}
}

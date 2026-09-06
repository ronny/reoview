import Foundation

/// One NVR user. The password never appears in a description or a log line.
public struct Credentials: Sendable, Hashable {
    public let user: String
    public let password: String

    public init(user: String, password: String) {
        self.user = user
        self.password = password
    }

    /// The password as an RTSP or FLV URL needs it.
    ///
    /// This matches `urllib.parse.quote(password, safe="")` in `reolink_aio`:
    /// every character except the RFC 3986 unreserved set is escaped.
    public var percentEncodedPassword: String {
        password.addingPercentEncoding(withAllowedCharacters: .rfc3986Unreserved) ?? ""
    }
}

extension Credentials: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "Credentials(user: \(user), password: <redacted>)" }
    public var debugDescription: String { description }
}

extension CharacterSet {
    static let rfc3986Unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

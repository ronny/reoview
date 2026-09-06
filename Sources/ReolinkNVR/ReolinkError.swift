import Foundation

/// Every failure that `NVRClient` can report.
///
/// The numeric `rspCode` survives into `api`. Code `-6` means a stale token,
/// and the client branches on it rather than on a message.
public enum ReolinkError: Error, Sendable {
    /// The `Transport` could not complete the round trip.
    case transport(any Error)

    /// The NVR answered, but not with 200.
    case httpStatus(Int)

    /// The NVR answered 200 with an error element in the JSON array.
    case api(cmd: String, rspCode: Int, detail: String)

    /// The body was not the shape this command expects.
    case decoding(cmd: String, underlying: any Error)

    /// The credentials were rejected, or the login response carried no token.
    case authentication(detail: String)

    public static let badTokenCode = -6

    public var rspCode: Int? {
        if case let .api(_, code, _) = self { return code }
        return nil
    }

    /// True when a fresh login is worth trying once.
    public var isStaleToken: Bool {
        switch self {
        case let .api(_, code, _): code == Self.badTokenCode
        case let .httpStatus(status): status == 401
        default: false
        }
    }
}

extension ReolinkError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .transport(error):
            "Could not reach the NVR: \(error.localizedDescription)"
        case let .httpStatus(status):
            "The NVR answered with HTTP status \(status)."
        case let .api(cmd, rspCode, detail):
            "\(cmd) failed with code \(rspCode): \(detail)"
        case let .decoding(cmd, underlying):
            "Could not read the \(cmd) response: \(underlying)"
        case let .authentication(detail):
            "The NVR rejected the credentials: \(detail)"
        }
    }
}

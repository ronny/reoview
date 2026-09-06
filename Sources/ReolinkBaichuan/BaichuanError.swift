import Foundation

/// Every failure the Baichuan client can report.
///
/// The device's own number survives into `status`, because the client branches
/// on it: 401 is bad credentials, 422 means another client holds the talk slot,
/// and 400 means the device parsed the request and rejected it.
public enum BaichuanError: Error, Sendable {
    /// The `BaichuanConnection` could not open, write, or read.
    case connection(any Error)

    /// No reply arrived before the deadline.
    case timeout(messageID: UInt32)

    /// The device answered with a status outside the success set.
    case status(messageID: UInt32, status: Int)

    /// The bytes on the wire were not a Baichuan message.
    case protocolViolation(detail: String)

    /// A body did not decrypt, or decrypted to something that is not XML.
    case decryption(detail: String)

    /// A body decrypted but did not hold the elements this command needs.
    case decode(detail: String)

    public var status: Int? {
        if case let .status(_, status) = self { return status }
        return nil
    }

    /// The credentials were rejected.
    public var isUnauthorized: Bool { status == BcStatus.unauthorized }

    /// Another client holds the talk slot. Send message 11, then retry once.
    public var isTalkSlotBusy: Bool { status == BcStatus.busy }
}

extension BaichuanError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .connection(error):
            "Could not reach the device on port 9000: \(error.localizedDescription)"
        case let .timeout(messageID):
            "The device did not answer message \(messageID) in time."
        case let .status(messageID, status):
            "Message \(messageID) failed with status \(status)."
        case let .protocolViolation(detail):
            "The device sent something that is not a Baichuan message: \(detail)"
        case let .decryption(detail):
            "Could not decrypt the message body: \(detail)"
        case let .decode(detail):
            "Could not read the message body: \(detail)"
        }
    }
}

/// The status field at header offset 16, on a 24-byte header.
///
/// Three numbers mean success, not one. Message 199 answers **300** on
/// firmware v3.6.5.562 and that is a normal, fully populated reply, so a client
/// that only accepts 200 loses the whole `Support` response. `reolink_aio`
/// makes the same allowance in `base_protocol.py`.
///
/// A 20-byte header carries no status at all: the same two bytes hold the
/// encryption word during login, so `0xdd12` there is a cipher, not a failure.
public enum BcStatus {
    public static let ok = 200
    public static let created = 201
    public static let multipleChoices = 300
    public static let badRequest = 400
    public static let unauthorized = 401
    public static let busy = 422

    public static let successes: Set<Int> = [ok, created, multipleChoices]

    public static func isSuccess(_ status: Int) -> Bool { successes.contains(status) }
}

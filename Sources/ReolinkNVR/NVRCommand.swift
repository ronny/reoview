import Foundation

/// One entry in the JSON array that the Reolink API takes as a request body.
///
/// Every response quirk of a command is decoded in that command's `Response`
/// type, never at a call site.
public protocol NVRCommand: Sendable {
    associatedtype Param: Encodable & Sendable
    associatedtype Response: Decodable & Sendable

    /// The `cmd` string, for example `GetAbility`.
    static var cmd: String { get }

    /// The `action` field. `0` asks for values, `1` asks for values and ranges.
    var action: Int { get }

    var param: Param { get }
}

public extension NVRCommand {
    var action: Int { 0 }
}

/// A command that carries no parameters.
public struct NoParam: Encodable, Sendable {
    public init() {}
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode([String: String]())
    }
}

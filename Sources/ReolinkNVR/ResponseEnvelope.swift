import Foundation

struct DynamicKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// The `cmd`, `code` and `error` fields that every element of a Reolink
/// response array carries, whatever the command was.
struct ResponseEnvelope: Decodable, Sendable {
    struct Failure: Decodable, Sendable {
        let rspCode: Int
        let detail: String?
    }

    let cmd: String?
    let code: Int?
    let error: Failure?
}

/// The payload of one response element.
///
/// The NVR puts it under `value`, or under `initial` when it answers an
/// `action: 1` request. Command responses read their fields through this type
/// so that neither quirk reaches a call site.
struct ResponseValue {
    private let container: KeyedDecodingContainer<DynamicKey>

    init(from decoder: any Decoder) throws {
        let top = try decoder.container(keyedBy: DynamicKey.self)
        for key in ["value", "initial"] where top.contains(DynamicKey(key)) {
            container = try top.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey(key))
            return
        }
        throw DecodingError.keyNotFound(
            DynamicKey("value"),
            .init(codingPath: top.codingPath, debugDescription: "No value or initial object in the response element")
        )
    }

    func decode<T: Decodable>(_ type: T.Type, _ key: String) throws -> T {
        try container.decode(type, forKey: DynamicKey(key))
    }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, _ key: String) throws -> T? {
        try container.decodeIfPresent(type, forKey: DynamicKey(key))
    }

    /// Reads a field that some firmwares wrap in a one-element array.
    func decodeUnwrapping<T: Decodable>(_ type: T.Type, _ key: String) throws -> T {
        if let single = try? container.decode(type, forKey: DynamicKey(key)) { return single }
        let list = try container.decode([T].self, forKey: DynamicKey(key))
        guard let first = list.first else {
            throw DecodingError.dataCorruptedError(
                forKey: DynamicKey(key), in: container, debugDescription: "Empty array where one \(type) was expected"
            )
        }
        return first
    }

    /// Every key of the payload, so that a command can read a map whose keys
    /// are not known in advance.
    var keys: [String] { container.allKeys.map(\.stringValue) }
}

extension KeyedDecodingContainer {
    /// Reads an integer that some firmwares send as a string. `reolink_aio`
    /// casts the PTZ preset `id` and `enable` fields with `int()` for exactly
    /// this reason.
    func decodeLenientInt(forKey key: Key) throws -> Int {
        if let number = try? decode(Int.self, forKey: key) { return number }
        let text = try decode(String.self, forKey: key)
        guard let number = Int(text) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self, debugDescription: "\"\(text)\" is not an integer"
            )
        }
        return number
    }
}

import Foundation

/// Moves bytes to the NVR and back.
///
/// This is the seam that tests replace with a fixture player. Implementations
/// must not retry, refresh tokens, or interpret the response body.
public protocol Transport: Sendable {
    func send(_ request: TransportRequest) async throws -> TransportResponse
}

public struct TransportRequest: Sendable {
    public var url: URL
    public var method: String
    public var body: Data?
    public var contentType: String?

    public init(url: URL, method: String = "POST", body: Data? = nil, contentType: String? = "application/json") {
        self.url = url
        self.method = method
        self.body = body
        self.contentType = contentType
    }
}

public struct TransportResponse: Sendable {
    public var statusCode: Int
    public var body: Data
    public var contentType: String?

    public init(statusCode: Int, body: Data, contentType: String? = nil) {
        self.statusCode = statusCode
        self.body = body
        self.contentType = contentType
    }
}

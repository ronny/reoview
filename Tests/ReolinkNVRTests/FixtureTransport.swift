import Foundation
import ReolinkNVR

/// Replays recorded JSON and keeps every request it was given.
actor FixtureTransport: Transport {
    typealias Handler = @Sendable (Sent) async throws -> TransportResponse

    /// One request, with the parts a test wants to assert on already pulled out.
    struct Sent: Sendable {
        let index: Int
        let request: TransportRequest

        var url: URL { request.url }
        var cmd: String? { queryItem("cmd") }
        var token: String? { queryItem("token") }

        var bodyElements: [[String: Any]] {
            guard let body = request.body,
                  let array = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]]
            else { return [] }
            return array
        }

        private func queryItem(_ name: String) -> String? {
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == name }?.value
        }
    }

    private let handler: Handler
    private(set) var sent: [Sent] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Answers every request with the next body in the list.
    init(replaying bodies: [String]) {
        let bodies = bodies
        handler = { sent in
            guard sent.index < bodies.count else {
                throw FixtureExhausted(index: sent.index)
            }
            return TransportResponse(statusCode: 200, body: Data(bodies[sent.index].utf8))
        }
    }

    func send(_ request: TransportRequest) async throws -> TransportResponse {
        let sent = Sent(index: self.sent.count, request: request)
        self.sent.append(sent)
        return try await handler(sent)
    }

    func requests(cmd: String) -> [Sent] {
        sent.filter { $0.cmd == cmd }
    }
}

struct FixtureExhausted: Error {
    let index: Int
}

extension TransportResponse {
    static func ok(_ json: String) -> TransportResponse {
        TransportResponse(statusCode: 200, body: Data(json.utf8), contentType: "text/html")
    }
}

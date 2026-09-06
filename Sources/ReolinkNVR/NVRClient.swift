import Foundation

/// Talks to one Reolink host.
///
/// The actor holds one HTTP request in flight at a time, because Reolink HTTP
/// stacks are fragile under concurrency and the NVR caps concurrent sessions.
/// Parallelism comes from batching many commands into one POST.
public actor NVRClient {
    private let host: String
    private let credentials: Credentials
    private let transport: any Transport

    private var token: String?
    private var loginTask: Task<String, Error>?

    public init(host: String, credentials: Credentials, transport: any Transport) {
        self.host = host
        self.credentials = credentials
        self.transport = transport
    }

    public func send<C: NVRCommand>(_ command: C, channel: Int? = nil) async throws -> C.Response {
        let responses = try await send([(command: command, channel: channel)])
        guard let first = responses.first else {
            throw ReolinkError.decoding(cmd: C.cmd, underlying: BatchSizeMismatch(expected: 1, received: 0))
        }
        return first
    }

    /// Sends every command in one POST, as one JSON array.
    ///
    /// The responses come back in request order, one per command.
    public func send<C: NVRCommand>(_ commands: [(command: C, channel: Int?)]) async throws -> [C.Response] {
        guard !commands.isEmpty else { return [] }

        let body = try requestBody(commands)
        let needsToken = !Self.isSessionCommand(C.cmd)
        let token = needsToken ? try await currentToken() : nil

        do {
            return try await perform(cmd: C.cmd, body: body, token: token, expecting: commands.count)
        } catch let error as ReolinkError where error.isStaleToken {
            guard let token else { throw error }
            let fresh = try await refreshedToken(replacing: token)
            return try await perform(cmd: C.cmd, body: body, token: fresh, expecting: commands.count)
        }
    }

    public func login() async throws {
        _ = try await currentToken()
    }

    /// The NVR caps concurrent sessions, and a stale token keeps one open, so
    /// this runs on quit.
    public func logout() async throws {
        guard let token else { return }
        self.token = nil
        loginTask = nil
        let body = try requestBody([(command: Logout(), channel: nil)])
        _ = try await perform(cmd: Logout.cmd, body: body, token: token, expecting: 1) as [Logout.Response]
    }

    public var isLoggedIn: Bool { token != nil }

    private static func isSessionCommand(_ cmd: String) -> Bool {
        cmd == Login.cmd || cmd == Logout.cmd
    }

    private func currentToken() async throws -> String {
        if let token { return token }
        if let loginTask { return try await loginTask.value }
        return try await startLogin()
    }

    /// Single flight. Concurrent callers that meet the same stale token all
    /// await one `Login`, and callers that arrive after it finishes take the
    /// new token without a second one.
    private func refreshedToken(replacing stale: String) async throws -> String {
        if let token, token != stale { return token }
        // A login in flight always started after `stale` was issued, because a
        // login clears `loginTask` before it hands its token to anybody.
        if let loginTask { return try await loginTask.value }
        return try await startLogin()
    }

    private func startLogin() async throws -> String {
        token = nil
        // The task, not its caller, publishes the token. A caller cannot do it
        // after `await`, because the other waiters resume in any order and
        // would read the token that was just rejected.
        let task = Task<String, Error> { [host, credentials, transport] in
            defer { self.loginTask = nil }
            let fresh = try await Self.performLogin(host: host, credentials: credentials, transport: transport)
            self.token = fresh
            return fresh
        }
        loginTask = task
        return try await task.value
    }

    private nonisolated static func performLogin(
        host: String,
        credentials: Credentials,
        transport: any Transport
    ) async throws -> String {
        let body = try RequestBody.data(for: [(command: Login(credentials: credentials), channel: nil)])
        let request = TransportRequest(url: try Self.url(host: host, cmd: Login.cmd, token: nil), body: body)
        let response = try await Self.roundTrip(request, through: transport)

        do {
            let logins: [Login.Response] = try Self.decode(response.body, cmd: Login.cmd, expecting: 1)
            guard let token = logins.first?.token, !token.isEmpty else {
                throw ReolinkError.authentication(detail: "The login response carried no token")
            }
            return token
        } catch let error as ReolinkError {
            guard case let .api(_, _, detail) = error else { throw error }
            throw ReolinkError.authentication(detail: detail)
        }
    }

    private func perform<R: Decodable & Sendable>(
        cmd: String,
        body: Data,
        token: String?,
        expecting count: Int
    ) async throws -> [R] {
        let request = TransportRequest(url: try Self.url(host: host, cmd: cmd, token: token), body: body)
        let response = try await Self.roundTrip(request, through: transport)
        return try Self.decode(response.body, cmd: cmd, expecting: count)
    }

    private nonisolated static func roundTrip(
        _ request: TransportRequest,
        through transport: any Transport
    ) async throws -> TransportResponse {
        let response: TransportResponse
        do {
            response = try await transport.send(request)
        } catch let error as ReolinkError {
            throw error
        } catch {
            throw ReolinkError.transport(error)
        }

        guard response.statusCode == 200 else {
            throw ReolinkError.httpStatus(response.statusCode)
        }
        return response
    }

    private nonisolated static func url(host: String, cmd: String, token: String?) throws -> URL {
        var string = "https://\(host)/api.cgi?cmd=\(cmd)"
        if let token {
            let escaped = token.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? token
            string += "&token=\(escaped)"
        }
        guard let url = URL(string: string) else {
            throw ReolinkError.transport(URLError(.badURL))
        }
        return url
    }

    private nonisolated func requestBody<C: NVRCommand>(_ commands: [(command: C, channel: Int?)]) throws -> Data {
        do {
            return try RequestBody.data(for: commands)
        } catch {
            throw ReolinkError.decoding(cmd: C.cmd, underlying: error)
        }
    }

    private nonisolated static func decode<R: Decodable & Sendable>(
        _ data: Data,
        cmd: String,
        expecting count: Int
    ) throws -> [R] {
        let decoder = JSONDecoder()

        let envelopes: [ResponseEnvelope]
        do {
            envelopes = try decoder.decode([ResponseEnvelope].self, from: data)
        } catch {
            throw ReolinkError.decoding(cmd: cmd, underlying: error)
        }

        for envelope in envelopes {
            guard let failure = envelope.error ?? (envelope.code == 0 ? nil : ResponseEnvelope.Failure(rspCode: envelope.code ?? -1, detail: nil)) else {
                continue
            }
            throw ReolinkError.api(
                cmd: envelope.cmd ?? cmd,
                rspCode: failure.rspCode,
                detail: failure.detail ?? ""
            )
        }

        guard envelopes.count == count else {
            throw ReolinkError.decoding(cmd: cmd, underlying: BatchSizeMismatch(expected: count, received: envelopes.count))
        }

        do {
            return try decoder.decode([R].self, from: data)
        } catch {
            throw ReolinkError.decoding(cmd: cmd, underlying: error)
        }
    }
}

struct BatchSizeMismatch: Error, CustomStringConvertible {
    let expected: Int
    let received: Int

    var description: String { "Expected \(expected) response elements, received \(received)" }
}

/// Builds the JSON array that the API takes as a request body.
///
/// The channel is merged into the command's own `param`, so a command type does
/// not have to carry one.
enum RequestBody {
    static func data<C: NVRCommand>(for commands: [(command: C, channel: Int?)]) throws -> Data {
        let elements = try commands.map { try element($0.command, channel: $0.channel) }
        return try JSONSerialization.data(withJSONObject: elements, options: [.sortedKeys])
    }

    static func element<C: NVRCommand>(_ command: C, channel: Int?) throws -> [String: Any] {
        var param = try object(from: command.param)
        if let channel {
            param["channel"] = channel
        }
        return ["cmd": C.cmd, "action": command.action, "param": param]
    }

    private static func object(from param: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(param)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}

extension CharacterSet {
    static let urlQueryValueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?"))
}

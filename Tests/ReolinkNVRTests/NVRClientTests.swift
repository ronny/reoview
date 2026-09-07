import Foundation
import Testing
@testable import ReolinkNVR

private let credentials = Credentials(user: "viewer", password: "s3cr3t")

private func makeClient(_ transport: any Transport) -> NVRClient {
    NVRClient(host: "192.0.2.10", credentials: credentials, transport: transport)
}

@Suite("Request shape")
struct RequestShapeTests {
    @Test("Login posts the documented body and carries no token")
    func loginBody() async throws {
        let transport = FixtureTransport(replaying: [Fixture.login])
        let client = makeClient(transport)

        try await client.login()

        let sent = try #require(await transport.sent.first)
        #expect(sent.url.absoluteString == "https://192.0.2.10/api.cgi?cmd=Login")
        #expect(sent.token == nil)

        let element = try #require(sent.bodyElements.first)
        #expect(element["cmd"] as? String == "Login")
        let param = try #require(element["param"] as? [String: Any])
        let user = try #require(param["User"] as? [String: Any])
        #expect(user["Version"] as? String == "0")
        #expect(user["userName"] as? String == "viewer")
        #expect(user["password"] as? String == "s3cr3t")
    }

    @Test("A batch of commands becomes one POST with a JSON array body")
    func batchIsOneRequest() async throws {
        let transport = FixtureTransport(replaying: [Fixture.login, Fixture.eventsTwoChannels])
        let client = makeClient(transport)

        let responses = try await client.send([
            (command: GetEvents(), channel: 0),
            (command: GetEvents(), channel: 1),
        ])

        #expect(responses.count == 2)

        let events = try #require(await transport.requests(cmd: "GetEvents").first)
        #expect(await transport.sent.count == 2, "one login and one batched POST")
        #expect(events.url.absoluteString == "https://192.0.2.10/api.cgi?cmd=GetEvents&token=e7d2c8f0a1b34567")
        #expect(events.request.method == "POST")
        #expect(events.request.contentType == "application/json")

        let elements = events.bodyElements
        #expect(elements.count == 2)
        for (index, element) in elements.enumerated() {
            #expect(element["cmd"] as? String == "GetEvents")
            #expect(element["action"] as? Int == 0)
            let param = try #require(element["param"] as? [String: Any])
            #expect(param["channel"] as? Int == index)
        }
    }

    @Test("The channel is merged into a command's own param")
    func channelMergedIntoParam() throws {
        let element = try RequestBody.element(GetAbility(userName: "viewer"), channel: 3)
        let param = try #require(element["param"] as? [String: Any])
        #expect(param["channel"] as? Int == 3)
        #expect((param["User"] as? [String: Any])?["userName"] as? String == "viewer")
    }
}

@Suite("Token refresh")
struct TokenRefreshTests {
    /// Rejects the first token with `rspCode` -6 and accepts every later one.
    private static func staleTokenTransport(loginBodies: [String]) -> FixtureTransport {
        let logins = Counter()
        return FixtureTransport { sent in
            if sent.cmd == "Login" {
                let index = await logins.next()
                return .ok(loginBodies[min(index, loginBodies.count - 1)])
            }
            guard sent.token == "9f10bc22de334455" else {
                return .ok(Fixture.badToken)
            }
            return .ok(Fixture.devInfo)
        }
    }

    @Test("A -6 response triggers one re-login and a replay")
    func staleTokenIsReplayed() async throws {
        let transport = Self.staleTokenTransport(loginBodies: [Fixture.login, Fixture.secondLogin])
        let client = makeClient(transport)

        let info = try await client.send(GetDevInfo())

        #expect(info.devInfo.model == "RLN8-410")
        #expect(await transport.requests(cmd: "Login").count == 2)
        #expect(await transport.requests(cmd: "GetDevInfo").count == 2)
    }

    /// Repeated, because the order in which the waiters of one login resume is
    /// not fixed and an earlier version only failed in some of them.
    @Test("Eight concurrent commands that meet a stale token share one login", arguments: 0 ..< 25)
    func singleFlightLogin(round: Int) async throws {
        let transport = Self.staleTokenTransport(loginBodies: [Fixture.login, Fixture.secondLogin])
        let client = makeClient(transport)

        let results = try await withThrowingTaskGroup(of: GetDevInfo.Response.self) { group in
            for _ in 0 ..< 8 {
                group.addTask { try await client.send(GetDevInfo()) }
            }
            return try await group.reduce(into: [GetDevInfo.Response]()) { $0.append($1) }
        }

        #expect(results.count == 8)
        // One login to open the session, one to replace the rejected token.
        #expect(await transport.requests(cmd: "Login").count == 2)
        #expect(await transport.requests(cmd: "GetDevInfo").count == 16)
    }

    @Test("HTTP 401 refreshes the token too")
    func unauthorizedIsReplayed() async throws {
        let transport = FixtureTransport { sent in
            if sent.cmd == "Login" { return .ok(Fixture.login) }
            guard sent.index > 1 else {
                return TransportResponse(statusCode: 401, body: Data())
            }
            return .ok(Fixture.devInfo)
        }
        let client = makeClient(transport)

        _ = try await client.send(GetDevInfo())

        #expect(await transport.requests(cmd: "Login").count == 2)
    }

    @Test("A rejected login surfaces as an authentication error")
    func rejectedLogin() async throws {
        let transport = FixtureTransport { _ in .ok(Fixture.loginRejected) }
        let client = makeClient(transport)

        do {
            try await client.login()
            Issue.record("Expected a Reolink error")
        } catch let error as ReolinkError {
            guard case let .authentication(detail) = error else {
                Issue.record("Expected an authentication error, got \(error)")
                return
            }
            #expect(detail == "login failed")
        }
    }

    @Test("Logout clears the token and needs no further login")
    func logoutClearsTheToken() async throws {
        let transport = FixtureTransport(replaying: [Fixture.login, Fixture.logout])
        let client = makeClient(transport)

        try await client.login()
        #expect(await client.isLoggedIn)

        try await client.logout()
        #expect(await client.isLoggedIn == false)
        #expect(await transport.requests(cmd: "Logout").count == 1)
    }
}

@Suite("Request serialisation")
struct RequestSerialisationTests {
    @Test("Round trips never overlap")
    func roundTripsNeverOverlap() async throws {
        let probe = SerialisationProbe()
        let client = makeClient(probe)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for channel in 0 ..< 8 {
                group.addTask { _ = try await client.send(GetDevInfo(), channel: channel) }
            }
            try await group.waitForAll()
        }

        #expect(await probe.maximumOverlap == 1)
        #expect(await probe.arrivals.count == 8)
    }

    @Test("Queued callers keep their arrival order")
    func queuedCallersKeepTheirOrder() async throws {
        let probe = SerialisationProbe()
        let client = makeClient(probe)
        try await client.login()

        await probe.holdTheNextRequest()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = try await client.send(GetDevInfo(), channel: 0) }
            // The first caller holds the slot until the test lets it go, so the
            // rest queue, and each one is in the queue before the next starts.
            try await waitUntil { await probe.arrivals.count == 1 }

            for channel in 1 ..< 6 {
                group.addTask { _ = try await client.send(GetDevInfo(), channel: channel) }
                try await waitUntil { await client.queuedRequestCount == channel }
            }

            await probe.releaseTheHeldRequest()
            try await group.waitForAll()
        }

        #expect(await probe.arrivals == Array(0 ..< 6))
        #expect(await probe.maximumOverlap == 1)
    }

    /// Polls until `condition` holds, and fails the test if it never does.
    private func waitUntil(
        _ condition: () async -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0 ..< 2000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("The condition never held", sourceLocation: sourceLocation)
    }
}

/// Answers like a healthy NVR, and records how the round trips are spaced.
///
/// The sleep stands in for the network. Without a suspension here the client
/// could not overlap two requests even if it tried, so the test would pass on
/// a client that does not serialise.
actor SerialisationProbe: Transport {
    private(set) var maximumOverlap = 0
    /// The channel of every `GetDevInfo`, in the order the requests arrive.
    private(set) var arrivals: [Int] = []

    private var inFlight = 0
    private var holdsTheNextRequest = false
    private var held: CheckedContinuation<Void, Never>?

    func holdTheNextRequest() {
        holdsTheNextRequest = true
    }

    func releaseTheHeldRequest() {
        held?.resume()
        held = nil
    }

    func send(_ request: TransportRequest) async throws -> TransportResponse {
        inFlight += 1
        maximumOverlap = max(maximumOverlap, inFlight)
        defer { inFlight -= 1 }

        let element = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [[String: Any]]
        let cmd = element?.first?["cmd"] as? String
        if cmd == GetDevInfo.cmd, let channel = (element?.first?["param"] as? [String: Any])?["channel"] as? Int {
            arrivals.append(channel)
        }

        if holdsTheNextRequest {
            holdsTheNextRequest = false
            await withCheckedContinuation { held = $0 }
        } else {
            try? await Task.sleep(for: .milliseconds(2))
        }

        return .ok(cmd == Login.cmd ? Fixture.login : Fixture.devInfo)
    }
}

@Suite("Error mapping")
struct ErrorMappingTests {
    @Test("An error element keeps its rspCode and detail")
    func rspCodeIsKept() async throws {
        let transport = FixtureTransport { sent in
            sent.cmd == "Login" ? .ok(Fixture.login) : .ok(Fixture.abilityError)
        }
        let client = makeClient(transport)

        do {
            _ = try await client.send(GetEnc(), channel: 4)
            Issue.record("Expected a Reolink error")
        } catch let error as ReolinkError {
            guard case let .api(cmd, rspCode, detail) = error else {
                Issue.record("Expected an api error, got \(error)")
                return
            }
            #expect(cmd == "GetEnc")
            #expect(rspCode == -9)
            #expect(detail == "ability error")
            #expect(error.rspCode == -9)
            #expect(error.isStaleToken == false)
        }
    }

    @Test("-6 is the stale-token code")
    func badTokenCode() {
        let error = ReolinkError.api(cmd: "GetDevInfo", rspCode: -6, detail: "please login first")
        #expect(error.isStaleToken)
        #expect(ReolinkError.httpStatus(401).isStaleToken)
        #expect(ReolinkError.httpStatus(500).isStaleToken == false)
    }

    @Test("A non-200 status maps to httpStatus")
    func httpStatus() async throws {
        let transport = FixtureTransport { _ in TransportResponse(statusCode: 503, body: Data()) }
        let client = makeClient(transport)

        do {
            try await client.login()
            Issue.record("Expected a Reolink error")
        } catch let error as ReolinkError {
            guard case let .httpStatus(status) = error else {
                Issue.record("Expected an httpStatus error, got \(error)")
                return
            }
            #expect(status == 503)
        }
    }

    @Test("A transport failure is wrapped, not swallowed")
    func transportFailure() async throws {
        struct Unreachable: Error {}
        let transport = FixtureTransport { _ in throw Unreachable() }
        let client = makeClient(transport)

        do {
            try await client.login()
            Issue.record("Expected a Reolink error")
        } catch let error as ReolinkError {
            guard case let .transport(underlying) = error else {
                Issue.record("Expected a transport error, got \(error)")
                return
            }
            #expect(underlying is Unreachable)
        }
    }
}

/// A counter the fixture handlers share.
actor Counter {
    private var value = 0

    /// Returns the value before the increment.
    func next() -> Int {
        defer { value += 1 }
        return value
    }
}

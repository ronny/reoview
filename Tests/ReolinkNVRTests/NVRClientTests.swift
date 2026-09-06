import Foundation
import Testing
@testable import ReolinkNVR

private let credentials = Credentials(user: "viewer", password: "s3cr3t")

private func makeClient(_ transport: FixtureTransport) -> NVRClient {
    NVRClient(host: "192.168.8.215", credentials: credentials, transport: transport)
}

@Suite("Request shape")
struct RequestShapeTests {
    @Test("Login posts the documented body and carries no token")
    func loginBody() async throws {
        let transport = FixtureTransport(replaying: [Fixture.login])
        let client = makeClient(transport)

        try await client.login()

        let sent = try #require(await transport.sent.first)
        #expect(sent.url.absoluteString == "https://192.168.8.215/api.cgi?cmd=Login")
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
        #expect(events.url.absoluteString == "https://192.168.8.215/api.cgi?cmd=GetEvents&token=e7d2c8f0a1b34567")
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

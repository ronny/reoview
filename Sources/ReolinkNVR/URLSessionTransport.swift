import Foundation

/// The production `Transport`.
///
/// The NVR presents a self-signed certificate. The delegate accepts it for the
/// one configured host and rejects every other challenge, so no global trust
/// setting is weakened.
public final class URLSessionTransport: Transport {
    private let session: URLSession
    private let delegate: TrustDelegate

    public init(trustingSelfSignedCertificateFor host: String, configuration: URLSessionConfiguration = .ephemeral) {
        delegate = TrustDelegate(host: host)
        configuration.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func send(_ request: TransportRequest) async throws -> TransportResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        if let contentType = request.contentType {
            urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw ReolinkError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ReolinkError.transport(URLError(.badServerResponse))
        }

        return TransportResponse(
            statusCode: http.statusCode,
            body: data,
            contentType: http.value(forHTTPHeaderField: "Content-Type")
        )
    }
}

/// Decides whether a server-trust challenge is the one host whose self-signed
/// certificate the app accepts.
struct TrustPolicy: Sendable {
    let host: String

    func acceptsSelfSignedCertificate(challengeHost: String, authenticationMethod: String) -> Bool {
        authenticationMethod == NSURLAuthenticationMethodServerTrust
            && challengeHost.caseInsensitiveCompare(host) == .orderedSame
    }
}

/// Accepts the NVR's self-signed certificate, and nothing else.
private final class TrustDelegate: NSObject, URLSessionDelegate, Sendable {
    let policy: TrustPolicy

    init(host: String) {
        policy = TrustPolicy(host: host)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard policy.acceptsSelfSignedCertificate(
            challengeHost: space.host,
            authenticationMethod: space.authenticationMethod
        ), let trust = space.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}

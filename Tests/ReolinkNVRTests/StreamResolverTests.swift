import Foundation
import Testing
@testable import ReolinkNVR

@Suite("Stream candidates")
struct StreamResolverTests {
    private let resolver = StreamResolver(
        host: "192.0.2.10",
        credentials: Credentials(user: "viewer", password: "p@ss word/1")
    )

    private let driveway = "95270005BBBBBBBB"

    @Test("Wide main: preferred codec, flipped codec, then FLV raw and encoded")
    func wideMain() {
        let source = StreamSource(cameraID: driveway, lens: .wide, quality: .main)

        #expect(resolver.candidates(for: source, channel: 1, codec: .h265).map(\.absoluteString) == [
            "rtsp://viewer:p%40ss%20word%2F1@192.0.2.10:554/h265Preview_02_main",
            "rtsp://viewer:p%40ss%20word%2F1@192.0.2.10:554/h264Preview_02_main",
            "https://192.0.2.10/flv?port=1935&app=bcs&stream=channel1_main.bcs&user=viewer&password=p@ss%20word/1",
            "https://192.0.2.10/flv?port=1935&app=bcs&stream=channel1_main.bcs&user=viewer&password=p%40ss%20word%2F1",
        ])
    }

    @Test("Wide sub on channel 0 flips the codec the other way")
    func wideSub() {
        let source = StreamSource(cameraID: "95270005AAAAAAAA", lens: .wide, quality: .sub)

        #expect(resolver.candidates(for: source, channel: 0, codec: .h264).map(\.absoluteString) == [
            "rtsp://viewer:p%40ss%20word%2F1@192.0.2.10:554/h264Preview_01_sub",
            "rtsp://viewer:p%40ss%20word%2F1@192.0.2.10:554/h265Preview_01_sub",
            "https://192.0.2.10/flv?port=1935&app=bcs&stream=channel0_sub.bcs&user=viewer&password=p@ss%20word/1",
            "https://192.0.2.10/flv?port=1935&app=bcs&stream=channel0_sub.bcs&user=viewer&password=p%40ss%20word%2F1",
        ])
    }

    @Test("Telephoto is FLV first, because RTSP answers 404 on this NVR")
    func telephoto() {
        let source = StreamSource(cameraID: "uid-1", lens: .telephoto, quality: .main)
        let candidates = resolver.candidates(for: source, channel: 1, codec: .h265)
            .map(\.absoluteString)

        #expect(candidates == [
            "https://192.0.2.10/flv?port=1935&app=bcs&stream=channel1_ext.bcs&user=viewer&password=p@ss%20word/1",
            "https://192.0.2.10/flv?port=1935&app=bcs&stream=channel1_ext.bcs&user=viewer&password=p%40ss%20word%2F1",
            "rtsp://viewer:p%40ss%20word%2F1@192.0.2.10:554/Preview_02_autotrack",
        ])
    }

    @Test("The password is percent-encoded and never appears in the clear")
    func passwordEncoding() {
        let credentials = Credentials(user: "viewer", password: "a b&c=d/e?f#g")

        #expect(credentials.percentEncodedPassword == "a%20b%26c%3Dd%2Fe%3Ff%23g")
        #expect(credentials.description.contains("a b&c") == false)
        #expect(credentials.description.contains("<redacted>"))
    }
}

@Suite("Certificate trust")
struct TrustPolicyTests {
    private let policy = TrustPolicy(host: "192.0.2.10")

    @Test("The configured host's certificate is accepted, whatever its case")
    func acceptsTheConfiguredHost() {
        #expect(policy.acceptsSelfSignedCertificate(
            challengeHost: "192.0.2.10",
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        ))
        #expect(TrustPolicy(host: "NVR.local").acceptsSelfSignedCertificate(
            challengeHost: "nvr.local",
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        ))
    }

    @Test("Every other host and every other challenge falls back to the default")
    func rejectsEverythingElse() {
        #expect(policy.acceptsSelfSignedCertificate(
            challengeHost: "192.168.8.216",
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        ) == false)
        #expect(policy.acceptsSelfSignedCertificate(
            challengeHost: "example.com",
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        ) == false)
        #expect(policy.acceptsSelfSignedCertificate(
            challengeHost: "192.0.2.10",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        ) == false)
    }
}

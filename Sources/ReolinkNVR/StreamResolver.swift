import Foundation

/// Builds the ordered list of URLs to try for one `StreamSource`.
///
/// URL construction is not a pure function: the codec that `GetEnc` reports is
/// wrong often enough that `reolink_aio` flips it and tries again. The resolver
/// hands the whole list to the player, which is the probe.
public struct StreamResolver: Sendable {
    public let host: String
    public let rtspPort: Int
    public let rtmpPort: Int
    private let credentials: Credentials

    public init(host: String, credentials: Credentials, rtspPort: Int = 554, rtmpPort: Int = 1935) {
        self.host = host
        self.credentials = credentials
        self.rtspPort = rtspPort
        self.rtmpPort = rtmpPort
    }

    /// Candidates for `source` on `channel`, best first.
    ///
    /// `codec` is the preferred codec, from `GetEnc`. It is ignored for the
    /// telephoto lens, whose path carries no codec prefix.
    public func candidates(for source: StreamSource, channel: Int, codec: VideoCodec) -> [URL] {
        let number = String(format: "%02d", channel + 1)

        let paths: [String] = switch source.lens {
        case .telephoto:
            ["Preview_\(number)_autotrack"]
        case .wide:
            [
                "\(codec.rawValue)Preview_\(number)_\(source.quality.rawValue)",
                "\(codec.flipped.rawValue)Preview_\(number)_\(source.quality.rawValue)",
            ]
        }

        let flv = [
            flvURL(source: source, channel: channel, password: credentials.password),
            flvURL(source: source, channel: channel, password: credentials.percentEncodedPassword),
        ]
        return (paths.map(rtspURL(path:)) + flv).compactMap { $0 }
    }

    private func rtspURL(path: String) -> URL? {
        URL(string: "rtsp://\(credentials.user):\(credentials.percentEncodedPassword)@\(host):\(rtspPort)/\(path)")
    }

    /// reolink_aio says "FLV needs unencoded password" and sends the password
    /// raw, unlike RTSP. A raw password can also make a URL that will not parse.
    /// Both forms are therefore emitted as separate candidates, raw first, and
    /// the player decides which one the NVR accepts.
    ///
    /// reolink_aio has no verified FLV path for the telephoto lens. The stream
    /// name mirrors the RTSP one, which is the only form the NVR is known to
    /// accept.
    private func flvURL(source: StreamSource, channel: Int, password: String) -> URL? {
        let stream = source.lens == .telephoto ? "autotrack" : source.quality.rawValue
        let query = "port=\(rtmpPort)&app=bcs&stream=channel\(channel)_\(stream).bcs"
            + "&user=\(credentials.user)&password=\(password)"
        return URL(string: "https://\(host)/flv?\(query)")
    }
}

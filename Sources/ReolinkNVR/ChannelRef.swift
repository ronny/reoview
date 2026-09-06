import Foundation

/// Addresses one channel on one Reolink host.
///
/// In v1 the host is always the NVR. The type exists so that a direct
/// connection to a camera needs no change to command signatures.
public struct ChannelRef: Hashable, Sendable, Codable {
    public let host: String
    public let channel: Int

    public init(host: String, channel: Int) {
        self.host = host
        self.channel = channel
    }

    /// The two-digit, 1-based channel number that RTSP paths use.
    public var rtspChannelNumber: String {
        String(format: "%02d", channel + 1)
    }
}

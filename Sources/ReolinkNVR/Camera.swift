import Foundation

public enum Lens: String, Sendable, Hashable, Codable, CaseIterable {
    case wide
    case telephoto
}

public enum Quality: String, Sendable, Hashable, Codable, CaseIterable {
    case main
    case sub
}

/// A physical device on one channel of the NVR.
///
/// The identity is the channel UID, not the channel index. A change of PoE port
/// moves the index and keeps the UID.
public struct Camera: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public let name: String
    public let model: String?
    public let channel: Int

    public init(id: String, name: String, model: String?, channel: Int) {
        self.id = id
        self.name = name
        self.model = model
        self.channel = channel
    }

    public init(status: GetChannelstatus.Status) {
        let uid = status.uid.flatMap { $0.isEmpty ? nil : $0 }
        id = uid ?? "ch\(status.channel)"
        // Some firmwares put "0" or "1" in the name field instead of a name.
        name = status.name.flatMap { ["", "0", "1"].contains($0) ? nil : $0 } ?? "Channel \(status.channel)"
        model = status.typeInfo
        channel = status.channel
    }

    /// The online channels of a `GetChannelstatus` response, in channel order.
    public static func cameras(from response: GetChannelstatus.Response) -> [Camera] {
        response.status
            .filter(\.isOnline)
            .sorted { $0.channel < $1.channel }
            .map(Camera.init(status:))
    }

    /// The feeds this camera can play. The telephoto lens has no sub stream.
    public func streamSources(hasTelephotoLens: Bool) -> [StreamSource] {
        var sources = [
            StreamSource(cameraID: id, lens: .wide, quality: .main),
            StreamSource(cameraID: id, lens: .wide, quality: .sub),
        ]
        if hasTelephotoLens {
            sources.append(StreamSource(cameraID: id, lens: .telephoto, quality: .main))
        }
        return sources
    }
}

/// One playable feed: a camera, a lens, and a quality.
public struct StreamSource: Identifiable, Sendable, Hashable, Codable {
    public let cameraID: String
    public let lens: Lens
    public let quality: Quality

    public init(cameraID: String, lens: Lens, quality: Quality) {
        self.cameraID = cameraID
        self.lens = lens
        self.quality = quality
    }

    public var id: String { "\(cameraID)/\(lens.rawValue)/\(quality.rawValue)" }
}

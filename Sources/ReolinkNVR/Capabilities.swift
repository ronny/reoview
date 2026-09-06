import Foundation

/// The parsed `GetAbility` response.
///
/// `GetAbility` reports host-wide abilities beside an `abilityChn` array with
/// one entry per channel. Every control in the app is gated on a lookup here.
public struct Capabilities: Sendable, Hashable {
    public struct Ability: Decodable, Sendable, Hashable {
        public let ver: Int
        public let permit: Int?

        public init(ver: Int, permit: Int? = nil) {
            self.ver = ver
            self.permit = permit
        }
    }

    public let host: [String: Ability]
    public let channels: [[String: Ability]]

    /// Commands whose presence `GetAbility` does not report. See
    /// `recording(command:present:)`.
    public let probedCommands: [String: Int]

    public init(
        host: [String: Ability] = [:],
        channels: [[String: Ability]] = [],
        probedCommands: [String: Int] = [:]
    ) {
        self.host = host
        self.channels = channels
        self.probedCommands = probedCommands
    }

    public func abilityVersion(_ name: String, channel: Int? = nil) -> Int {
        if let probed = probedCommands[name] { return probed }
        guard let channel else { return host[name]?.ver ?? 0 }
        guard channels.indices.contains(channel) else { return 0 }
        return channels[channel][name]?.ver ?? 0
    }

    public func supports(_ name: String, channel: Int? = nil) -> Bool {
        abilityVersion(name, channel: channel) > 0
    }

    public var channelCount: Int { channels.count }

    /// The TrackMix reports its second lens as an extra stream on the same
    /// channel, not as an extra channel.
    public func hasTelephotoLens(channel: Int) -> Bool {
        supports("supportAutoTrackStream", channel: channel)
    }

    /// `GetAbility` carries no key for `GetEvents`. `reolink_aio` learns it by
    /// sending the command once and looking for a non-error element, so the
    /// answer only becomes true after `recording(command:present:)`.
    public var supportsGetEvents: Bool { supports("GetEvents") }

    public func recording(command: String, present: Bool) -> Capabilities {
        var probed = probedCommands
        probed[command] = present ? 1 : 0
        return Capabilities(host: host, channels: channels, probedCommands: probed)
    }
}

extension Capabilities: Decodable {
    /// Skips any ability whose value is not a `{ver, permit}` object, so that
    /// one unknown shape does not fail the whole response.
    private struct LenientAbility: Decodable {
        let ability: Ability?

        init(from decoder: any Decoder) throws {
            ability = try? Ability(from: decoder)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        var host: [String: Ability] = [:]
        var channels: [[String: Ability]] = []

        for key in container.allKeys {
            if key.stringValue == "abilityChn" {
                channels = try container.decode([[String: LenientAbility]].self, forKey: key)
                    .map { $0.compactMapValues(\.ability) }
            } else if let ability = try? container.decode(LenientAbility.self, forKey: key).ability {
                host[key.stringValue] = ability
            }
        }

        self.init(host: host, channels: channels)
    }
}

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

/// The abilities that gate the controls of milestone 4.
///
/// Every rule here is copied from `reolink_aio`'s `construct_capabilities`. A
/// few of its rules also read a `Get*` response, which `GetAbility` cannot
/// stand in for; those are named on the accessor.
public extension Capabilities {
    /// `ptzType`, not `ptzCtrl`, is what `reolink_aio` reads. The version names
    /// a family of movements rather than a count.
    func ptzType(channel: Int) -> Int { abilityVersion("ptzType", channel: channel) }

    func supportsPtz(channel: Int) -> Bool { ptzType(channel: channel) != 0 }

    /// Left and right, and the pad as a whole.
    func supportsPan(channel: Int) -> Bool {
        [2, 3, 5, 6, 7].contains(ptzType(channel: channel))
    }

    /// Up and down. One `ptzType` pans without tilting, so the two differ.
    func supportsTilt(channel: Int) -> Bool {
        [2, 3, 5, 6].contains(ptzType(channel: channel))
    }

    func supportsPtzPresets(channel: Int) -> Bool {
        supportsPan(channel: channel) && supports("ptzPreset", channel: channel)
    }

    /// `GetAbility` carries no key for `GetPtzGuard`. `reolink_aio` probes for
    /// the command, so this stays false until `recording(command:present:)`.
    func supportsPtzGuard(channel: Int) -> Bool {
        supportsPan(channel: channel) && supports("GetPtzGuard")
    }

    /// Whether `PtzCtrl` takes a `speed` field.
    func supportsPtzSpeed(channel: Int) -> Bool {
        guard [2, 3].contains(ptzType(channel: channel)) else { return false }
        // reolink_aio reads supportPtzSpeed with no_key_return=1, so a channel
        // that never names the key counts as supporting speed.
        guard channels.indices.contains(channel),
              let ability = channels[channel]["supportPtzSpeed"]
        else { return true }
        return ability.ver > 0
    }

    /// Optical zoom on those `ptzType` values, digital zoom otherwise.
    ///
    /// `reolink_aio` also insists that `GetZoomFocus` came back with a range.
    /// Only the response can say that, so check `GetZoomFocus.Response.zoomRange`
    /// as well.
    func supportsZoom(channel: Int) -> Bool {
        [1, 2, 5].contains(ptzType(channel: channel))
            || supports("supportDigitalZoom", channel: channel)
    }

    /// Floodlight, spotlight and `WhiteLed` are three names for one thing.
    /// `GetWhiteLed` is a probed command, like `GetPtzGuard`.
    func supportsFloodlight(channel: Int) -> Bool {
        supports("GetWhiteLed")
            && (supports("floodLight", channel: channel) || supports("supportFLswitch", channel: channel))
    }

    func supportsAutoTrack(channel: Int) -> Bool { supports("aiTrack", channel: channel) }

    /// `AudioAlarmPlay`. `reolink_aio` also wants `GetAudioAlarm` to have
    /// answered for the channel, which `GetAbility` cannot report.
    func supportsSiren(channel: Int) -> Bool {
        supports("alarmAudio", channel: channel) || supports("supportAudioAlarm", channel: channel)
    }

    /// The stored replies plus the `GetAutoReply` settings.
    func supportsQuickReply(channel: Int) -> Bool {
        supports("supportAudioFileList", channel: channel)
            && supports("supportAutoReply", channel: channel)
    }

    /// `QuickReplyPlay`. A camera can play a stored reply without carrying the
    /// auto-reply settings.
    func supportsQuickReplyPlayback(channel: Int) -> Bool {
        supportsQuickReply(channel: channel)
            || supports("supportAudioPlay", channel: channel)
            || supports("supportQuickReplyPlay", channel: channel)
    }

    /// `GetAudioCfg` is a probed command too. The channel is taken for the day
    /// the probe becomes per-channel.
    func supportsSpeakerVolume(channel: Int) -> Bool { supports("GetAudioCfg") }

    /// No ability key exists. `reolink_aio` decides from whether `GetManualRec`
    /// answered with an `enable` field, so this needs the probe as well.
    func supportsManualRecord(channel: Int) -> Bool { supports("GetManualRec") }
}

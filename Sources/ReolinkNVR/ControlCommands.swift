import Foundation

public struct GetAiCfg: NVRCommand {
    public static let cmd = "GetAiCfg"

    /// The auto-track method list only arrives under `range`, which needs
    /// `action: 1`.
    public let action = 1

    /// `GetAiCfg` puts its fields straight in `value`, with no wrapper object.
    public struct Response: Decodable, Sendable {
        public let channel: Int?

        /// The TrackMix reports auto track as `bSmartTrack`. Cameras without it
        /// use `aiTrack`, which doubles as the track-method selector, so the
        /// two are kept apart and `SetAiCfg` writes back the one that was read.
        public let smartTrack: Int?
        public let aiTrack: Int?

        public let disappearBackTime: Int?
        public let stopBackTime: Int?

        public init(from decoder: any Decoder) throws {
            let value = try ResponseValue(from: decoder)
            channel = try value.decodeIfPresent(Int.self, "channel")
            smartTrack = try value.decodeIfPresent(Int.self, "bSmartTrack")
            aiTrack = try value.decodeIfPresent(Int.self, "aiTrack")
            disappearBackTime = try value.decodeIfPresent(Int.self, "aiDisappearBackTime")
            stopBackTime = try value.decodeIfPresent(Int.self, "aiStopBackTime")
        }

        public var usesSmartTrack: Bool { smartTrack != nil }

        public var autoTrackEnabled: Bool {
            if let smartTrack { return smartTrack == 1 }
            return aiTrack == 1
        }
    }

    public let param = NoParam()

    public init() {}
}

public struct SetAiCfg: NVRCommand {
    public static let cmd = "SetAiCfg"

    public struct Param: Encodable, Sendable {
        let bSmartTrack: Int?
        let aiTrack: Int?
    }

    public typealias Response = Acknowledgement

    public let param: Param

    public init(smartTrack enabled: Bool) {
        param = Param(bSmartTrack: enabled ? 1 : 0, aiTrack: nil)
    }

    /// For a channel where `GetAiCfg` reported no `bSmartTrack`.
    public init(aiTrack enabled: Bool) {
        param = Param(bSmartTrack: nil, aiTrack: enabled ? 1 : 0)
    }
}

/// How the floodlight behaves at night. `reolink_aio` calls it the spotlight
/// mode, and floodlight, spotlight and `WhiteLed` are one thing.
public enum SpotlightMode: Int, Sendable, Hashable, Codable {
    case off = 0
    case auto = 1
    case onAtNight = 2
    case schedule = 3
    case autoAdaptive = 4
    case adaptive = 5
    case schedulePlus = -4
}

public struct GetWhiteLed: NVRCommand {
    public static let cmd = "GetWhiteLed"

    public struct WhiteLed: Decodable, Sendable, Hashable {
        public struct Schedule: Decodable, Sendable, Hashable {
            public let startHour: Int?
            public let startMin: Int?
            public let endHour: Int?
            public let endMin: Int?

            enum CodingKeys: String, CodingKey {
                case startHour = "StartHour"
                case startMin = "StartMin"
                case endHour = "EndHour"
                case endMin = "EndMin"
            }
        }

        public let channel: Int?
        public let state: Int?
        public let mode: Int?

        /// Brightness 0 to 100. Reolink shortens the field to `bright`.
        public let bright: Int?

        public let lightingSchedule: Schedule?

        public var isOn: Bool { state == 1 }

        public var spotlightMode: SpotlightMode? { mode.flatMap(SpotlightMode.init(rawValue:)) }

        enum CodingKeys: String, CodingKey {
            case channel, state, mode, bright
            case lightingSchedule = "LightingSchedule"
        }
    }

    public struct Response: Decodable, Sendable {
        public let whiteLed: WhiteLed

        public init(from decoder: any Decoder) throws {
            whiteLed = try ResponseValue(from: decoder).decode(WhiteLed.self, "WhiteLed")
        }
    }

    public let param = NoParam()

    public init() {}
}

public struct SetWhiteLed: NVRCommand {
    public static let cmd = "SetWhiteLed"

    public struct Param: Encodable, Sendable {
        let whiteLed: WhiteLed

        struct WhiteLed: Encodable, Sendable {
            let channel: Int
            let state: Int?
            let bright: Int?
            let mode: Int?
        }

        enum CodingKeys: String, CodingKey {
            case whiteLed = "WhiteLed"
        }
    }

    public typealias Response = Acknowledgement

    public let param: Param

    /// The channel goes inside the `WhiteLed` object, so it is given here and
    /// not to `NVRClient.send(_:channel:)`.
    public init(channel: Int, on: Bool? = nil, brightness: Int? = nil, mode: SpotlightMode? = nil) {
        param = Param(whiteLed: .init(
            channel: channel,
            state: on.map { $0 ? 1 : 0 },
            bright: brightness,
            mode: mode?.rawValue
        ))
    }
}

/// Sounds the siren.
public struct AudioAlarmPlay: NVRCommand {
    public static let cmd = "AudioAlarmPlay"

    /// Reolink spells the manual mode `manul`. It is their spelling, not a typo
    /// to correct.
    public enum AlarmMode: String, Sendable, Hashable, Codable {
        case manual = "manul"
        case times
    }

    /// `manual_switch` and `times` never travel together: `manul` carries the
    /// switch, `times` carries the count.
    public struct Param: Encodable, Sendable {
        let alarmMode: AlarmMode
        let manualSwitch: Int?
        let times: Int?

        enum CodingKeys: String, CodingKey {
            case alarmMode = "alarm_mode"
            case manualSwitch = "manual_switch"
            case times
        }
    }

    public typealias Response = Acknowledgement

    public let param: Param

    /// Holds the siren on, or turns it off again.
    public init(on: Bool) {
        param = Param(alarmMode: .manual, manualSwitch: on ? 1 : 0, times: nil)
    }

    /// Sounds the siren a fixed number of times and stops on its own.
    public init(times: Int) {
        param = Param(alarmMode: .times, manualSwitch: nil, times: times)
    }
}

public struct GetAudioFileList: NVRCommand {
    public static let cmd = "GetAudioFileList"

    public struct AudioFile: Decodable, Sendable, Hashable {
        public let id: Int
        public let fileName: String
    }

    public struct Response: Decodable, Sendable {
        public let files: [AudioFile]

        public init(from decoder: any Decoder) throws {
            // The field is null on a camera that holds no recordings.
            files = try ResponseValue(from: decoder)
                .decodeIfPresent([AudioFile].self, "AudioFileList") ?? []
        }
    }

    public let param = NoParam()

    public init() {}
}

public struct GetAutoReply: NVRCommand {
    public static let cmd = "GetAutoReply"

    public struct AutoReply: Decodable, Sendable, Hashable {
        public let channel: Int?
        public let enable: Int?
        public let fileId: Int?
        public let timeout: Int?

        public var isEnabled: Bool { enable == 1 }

        /// The file the camera plays by itself. `-1` means quick reply is off.
        public var selectedFileID: Int { fileId ?? -1 }
    }

    public struct Response: Decodable, Sendable {
        public let autoReply: AutoReply

        public init(from decoder: any Decoder) throws {
            autoReply = try ResponseValue(from: decoder).decode(AutoReply.self, "AutoReply")
        }
    }

    public let param = NoParam()

    public init() {}
}

/// Plays one of the files that `GetAudioFileList` reports.
public struct QuickReplyPlay: NVRCommand {
    public static let cmd = "QuickReplyPlay"

    public struct Param: Encodable, Sendable {
        let id: Int
    }

    public typealias Response = Acknowledgement

    public let param: Param

    public init(fileID: Int) {
        param = Param(id: fileID)
    }
}

public struct GetAudioCfg: NVRCommand {
    public static let cmd = "GetAudioCfg"

    public struct AudioCfg: Decodable, Sendable, Hashable {
        public let channel: Int?

        /// Speaker volume, 0 to 100.
        public let volume: Int?

        public let talkAndReplyVolume: Int?
        public let visitorVolume: Int?
        public let visitorLoudspeaker: Int?
    }

    public struct Response: Decodable, Sendable {
        public let audioCfg: AudioCfg

        public init(from decoder: any Decoder) throws {
            audioCfg = try ResponseValue(from: decoder).decode(AudioCfg.self, "AudioCfg")
        }
    }

    public let param = NoParam()

    public init() {}
}

public struct SetAudioCfg: NVRCommand {
    public static let cmd = "SetAudioCfg"

    public struct Param: Encodable, Sendable {
        let audioCfg: AudioCfg

        struct AudioCfg: Encodable, Sendable {
            let channel: Int
            let volume: Int?
        }

        enum CodingKeys: String, CodingKey {
            case audioCfg = "AudioCfg"
        }
    }

    public typealias Response = Acknowledgement

    public let param: Param

    /// The channel goes inside the `AudioCfg` object, so it is given here and
    /// not to `NVRClient.send(_:channel:)`. `volume` runs 0 to 100.
    public init(channel: Int, volume: Int) {
        param = Param(audioCfg: .init(channel: channel, volume: volume))
    }
}

public struct GetManualRec: NVRCommand {
    public static let cmd = "GetManualRec"

    public struct Rec: Decodable, Sendable, Hashable {
        public let channel: Int?
        public let enable: Int?
        public let duration: Int?

        public var isRecording: Bool { (enable ?? 0) > 0 }

        /// A firmware bug puts values above 1 in `enable`, and the camera then
        /// records until its battery runs down. `reolink_aio` answers by
        /// turning manual record off.
        public var hasStuckEnableFlag: Bool { (enable ?? 0) > 1 }
    }

    public struct Response: Decodable, Sendable {
        public let rec: Rec

        public init(from decoder: any Decoder) throws {
            rec = try ResponseValue(from: decoder).decode(Rec.self, "Rec")
        }
    }

    public let param = NoParam()

    public init() {}
}

public struct SetManualRec: NVRCommand {
    public static let cmd = "SetManualRec"

    /// Seconds. `reolink_aio` sends this with every start and nothing else.
    public static let defaultDuration = 600

    public struct Param: Encodable, Sendable {
        let rec: Rec

        struct Rec: Encodable, Sendable {
            let channel: Int
            let enable: Int
            let duration: Int?
        }

        enum CodingKeys: String, CodingKey {
            case rec = "Rec"
        }
    }

    public typealias Response = Acknowledgement

    public let param: Param

    /// The channel goes inside the `Rec` object, so it is given here and not to
    /// `NVRClient.send(_:channel:)`. A stop carries no duration.
    public init(channel: Int, recording: Bool, duration: Int = SetManualRec.defaultDuration) {
        param = Param(rec: .init(
            channel: channel,
            enable: recording ? 1 : 0,
            duration: recording ? duration : nil
        ))
    }
}

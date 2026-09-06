import Foundation

/// The `op` field of `PtzCtrl`.
public enum PtzOperation: String, Sendable, Hashable, Codable {
    case up = "Up"
    case down = "Down"
    case left = "Left"
    case right = "Right"
    case leftUp = "LeftUp"
    case leftDown = "LeftDown"
    case rightUp = "RightUp"
    case rightDown = "RightDown"
    case zoomIn = "ZoomInc"
    case zoomOut = "ZoomDec"
    case auto = "Auto"
    case stop = "Stop"

    /// Moves to a stored preset, and needs an `id` beside it. It is the one
    /// operation that `reolink_aio` keeps out of its `PtzEnum`.
    case toPosition = "ToPos"
}

/// Moves the camera, or sends it to a preset.
///
/// The pad sends a direction on press and `Stop` on release. Nothing else stops
/// the movement.
public struct PtzCtrl: NVRCommand {
    public static let cmd = "PtzCtrl"

    /// The speed the app asks for. `reolink_aio` leaves the field out for a
    /// channel that does not report `supportPtzSpeed`.
    public static let defaultSpeed = 25

    public struct Param: Encodable, Sendable {
        let op: PtzOperation
        let speed: Int?
        let id: Int?
    }

    public typealias Response = Acknowledgement

    public let param: Param

    /// Pass `speed: nil` for a channel where `Capabilities.supportsPtzSpeed`
    /// is false.
    public init(move direction: PtzOperation, speed: Int? = PtzCtrl.defaultSpeed) {
        param = Param(op: direction, speed: speed, id: nil)
    }

    public init(preset id: Int, speed: Int? = nil) {
        param = Param(op: .toPosition, speed: speed, id: id)
    }

    /// The release half of a press on the pad.
    public static var stop: PtzCtrl { PtzCtrl(move: .stop, speed: nil) }
}

public struct GetPtzPreset: NVRCommand {
    public static let cmd = "GetPtzPreset"

    public struct Preset: Decodable, Sendable, Hashable {
        public let id: Int
        public let name: String?
        public let enable: Int

        /// A slot only holds a position once it has been stored.
        public var isEnabled: Bool { enable == 1 }

        enum CodingKeys: String, CodingKey {
            case id, name, enable
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeLenientInt(forKey: .id)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            enable = try container.decodeLenientInt(forKey: .enable)
        }

        public init(id: Int, name: String?, enable: Int) {
            self.id = id
            self.name = name
            self.enable = enable
        }
    }

    public struct Response: Decodable, Sendable {
        public let presets: [Preset]

        public init(from decoder: any Decoder) throws {
            presets = try ResponseValue(from: decoder).decode([Preset].self, "PtzPreset")
        }

        /// The slots worth showing. `reolink_aio` drops the rest.
        public var storedPresets: [Preset] { presets.filter(\.isEnabled) }
    }

    public let param = NoParam()

    public init() {}
}

public struct GetPtzGuard: NVRCommand {
    public static let cmd = "GetPtzGuard"

    /// Reolink names the fields `benable` and `bexistPos`.
    public struct Guard: Decodable, Sendable, Hashable {
        public let channel: Int?
        public let benable: Int?
        public let bexistPos: Int?
        public let timeout: Int?

        /// A guard position only acts when it is switched on and one has been
        /// stored.
        public var isEnabled: Bool { benable == 1 && bexistPos == 1 }

        public var hasStoredPosition: Bool { bexistPos == 1 }

        /// Seconds of no movement before the camera returns to the position.
        public var returnTime: Int { timeout ?? 60 }
    }

    public struct Response: Decodable, Sendable {
        public let guardPosition: Guard

        public init(from decoder: any Decoder) throws {
            guardPosition = try ResponseValue(from: decoder).decode(Guard.self, "PtzGuard")
        }
    }

    public let param = NoParam()

    public init() {}
}

public struct SetPtzGuard: NVRCommand {
    public static let cmd = "SetPtzGuard"

    /// The `cmdStr` values. The lower-case `toPos` here is not the `ToPos` that
    /// `PtzCtrl` takes.
    public enum Operation: String, Sendable, Hashable, Codable {
        case setPosition = "setPos"
        case goToPosition = "toPos"
    }

    public struct Param: Encodable, Sendable {
        let ptzGuard: Guard

        struct Guard: Encodable, Sendable {
            let channel: Int
            let cmdStr: String
            let bSaveCurrentPos: Int?
            let benable: Int?
            let timeout: Int?
        }

        enum CodingKeys: String, CodingKey {
            case ptzGuard = "PtzGuard"
        }
    }

    public typealias Response = Acknowledgement

    public let param: Param

    /// The channel goes inside the `PtzGuard` object, so it is given here and
    /// not to `NVRClient.send(_:channel:)`.
    ///
    /// An `operation` of `nil` changes the settings and leaves the stored
    /// position alone. It still carries `cmdStr: "setPos"`, because that is
    /// what `reolink_aio` sends; only a named `setPos` adds `bSaveCurrentPos`,
    /// which is the field that overwrites the position with the current one.
    public init(
        channel: Int,
        operation: Operation? = nil,
        enabled: Bool? = nil,
        returnTime: Int? = nil
    ) {
        param = Param(ptzGuard: .init(
            channel: channel,
            cmdStr: (operation ?? .setPosition).rawValue,
            bSaveCurrentPos: operation == .setPosition ? 1 : nil,
            benable: enabled.map { $0 ? 1 : 0 },
            timeout: returnTime
        ))
    }
}

public struct GetZoomFocus: NVRCommand {
    public static let cmd = "GetZoomFocus"

    /// The zoom and focus ranges only arrive under `range`, which needs
    /// `action: 1`.
    public let action = 1

    public struct Bounds: Decodable, Sendable, Hashable {
        public let min: Int
        public let max: Int
    }

    public struct Response: Decodable, Sendable {
        public let zoom: Int
        public let focus: Int
        public let zoomRange: Bounds?
        public let focusRange: Bounds?

        private struct Positions: Decodable {
            struct Position: Decodable { let pos: Int }
            let zoom: Position
            let focus: Position
        }

        /// The range nests one level deeper than the value: `zoom.pos` is an
        /// `Int` under `value` and a `{min, max}` object under `range`.
        private struct Ranges: Decodable {
            struct Axis: Decodable { let pos: Bounds }
            let zoom: Axis
            let focus: Axis
        }

        public init(from decoder: any Decoder) throws {
            let positions = try ResponseValue(from: decoder).decode(Positions.self, "ZoomFocus")
            zoom = positions.zoom.pos
            focus = positions.focus.pos

            let ranges = try? decoder.container(keyedBy: DynamicKey.self)
                .decodeIfPresent([String: Ranges].self, forKey: DynamicKey("range"))?["ZoomFocus"]
            zoomRange = ranges?.zoom.pos
            focusRange = ranges?.focus.pos
        }
    }

    public let param = NoParam()

    public init() {}
}

public struct StartZoomFocus: NVRCommand {
    public static let cmd = "StartZoomFocus"

    /// `StartZoomFocus` has its own `op` values. They are not the `PtzCtrl` set.
    public enum Operation: String, Sendable, Hashable, Codable {
        case zoomPosition = "ZoomPos"
        case focusPosition = "FocusPos"
    }

    public struct Param: Encodable, Sendable {
        let zoomFocus: ZoomFocus

        struct ZoomFocus: Encodable, Sendable {
            let channel: Int
            let op: Operation
            let pos: Int
        }

        enum CodingKeys: String, CodingKey {
            case zoomFocus = "ZoomFocus"
        }
    }

    public typealias Response = Acknowledgement

    public let param: Param

    /// The channel goes inside the `ZoomFocus` object, so it is given here and
    /// not to `NVRClient.send(_:channel:)`. `position` must sit inside the
    /// range that `GetZoomFocus` reports.
    public init(channel: Int, zoom position: Int) {
        param = Param(zoomFocus: .init(channel: channel, op: .zoomPosition, pos: position))
    }

    public init(channel: Int, focus position: Int) {
        param = Param(zoomFocus: .init(channel: channel, op: .focusPosition, pos: position))
    }
}

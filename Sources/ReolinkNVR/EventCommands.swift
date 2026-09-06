import Foundation

/// One `{alarm_state, support}` pair.
///
/// `support` is absent in places. The default differs by field, so callers pass
/// it rather than reading a single `isSupported`.
public struct DetectionState: Decodable, Sendable, Hashable {
    public let alarmState: Bool
    public let support: Int?

    public init(alarmState: Bool, support: Int?) {
        self.alarmState = alarmState
        self.support = support
    }

    public func isSupported(whenAbsent fallback: Bool) -> Bool {
        guard let support else { return fallback }
        return support == 1
    }

    public var isSupported: Bool { isSupported(whenAbsent: false) }

    /// True only when the camera both supports the detection and reports it.
    public func isAlarming(supportWhenAbsent fallback: Bool = false) -> Bool {
        isSupported(whenAbsent: fallback) && alarmState
    }

    enum CodingKeys: String, CodingKey {
        case alarmState = "alarm_state"
        case support
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        alarmState = try container.decodeIfPresent(Int.self, forKey: .alarmState) == 1
        support = try container.decodeIfPresent(Int.self, forKey: .support)
    }
}

/// A detection entry the NVR may report as an object, as a bare `Int` on
/// firmware before 3.0.0.494, or as an array for the smart-AI types. The array
/// form is dropped, as `reolink_aio` drops it.
struct LenientDetection: Decodable, Sendable {
    let state: DetectionState?

    init(from decoder: any Decoder) throws {
        if let flag = try? decoder.singleValueContainer().decode(Int.self) {
            state = DetectionState(alarmState: flag == 1, support: 1)
            return
        }
        state = try? DetectionState(from: decoder)
    }
}

public struct GetEvents: NVRCommand {
    public static let cmd = "GetEvents"

    public struct Response: Decodable, Sendable {
        public let channel: Int
        public let motion: DetectionState?
        public let visitor: DetectionState?
        public let ai: [String: DetectionState]

        public init(from decoder: any Decoder) throws {
            let value = try ResponseValue(from: decoder)
            channel = try value.decode(Int.self, "channel")
            motion = try value.decodeIfPresent(DetectionState.self, "md")
            visitor = try value.decodeIfPresent(DetectionState.self, "visitor")
            ai = (try value.decodeIfPresent([String: LenientDetection].self, "ai") ?? [:])
                .compactMapValues(\.state)
        }

        /// `md` omits `support` on the cameras that have it, so an absent
        /// `support` counts as supported.
        public var motionDetected: Bool { motion?.isAlarming(supportWhenAbsent: true) ?? false }

        public var visitorDetected: Bool { visitor?.isAlarming() ?? false }

        /// True when the channel is a doorbell.
        public var supportsVisitor: Bool { visitor?.isSupported ?? false }

        public func aiDetected(_ type: String) -> Bool { ai[type]?.isAlarming() ?? false }

        public var supportedAITypes: [String] {
            ai.filter(\.value.isSupported).keys.sorted()
        }
    }

    public let param = NoParam()

    public init() {}
}

public struct GetMdState: NVRCommand {
    public static let cmd = "GetMdState"

    public struct Response: Decodable, Sendable {
        public let state: Int

        public var motionDetected: Bool { state == 1 }

        public init(from decoder: any Decoder) throws {
            state = try ResponseValue(from: decoder).decode(Int.self, "state")
        }
    }

    public let param = NoParam()

    public init() {}
}

public struct GetAiState: NVRCommand {
    public static let cmd = "GetAiState"

    public struct Response: Decodable, Sendable {
        public let channel: Int?
        public let ai: [String: DetectionState]

        public init(from decoder: any Decoder) throws {
            let value = try ResponseValue(from: decoder)
            channel = try value.decodeIfPresent(Int.self, "channel")
            var ai: [String: DetectionState] = [:]
            for key in value.keys where key != "channel" {
                if let state = try value.decodeIfPresent(LenientDetection.self, key)?.state {
                    ai[key] = state
                }
            }
            self.ai = ai
        }

        public func aiDetected(_ type: String) -> Bool { ai[type]?.isAlarming() ?? false }

        public var supportedAITypes: [String] {
            ai.filter(\.value.isSupported).keys.sorted()
        }
    }

    public let param = NoParam()

    public init() {}
}

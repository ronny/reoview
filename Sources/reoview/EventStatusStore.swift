import Observation
import ReolinkNVR

/// One kind of event the status strip can show for a camera.
enum Detection: String, CaseIterable, Sendable, Hashable, Identifiable {
    case motion
    case person
    case vehicle
    case pet
    case visitor

    var id: String { rawValue }

    var label: String {
        switch self {
        case .motion: "Motion"
        case .person: "Person"
        case .vehicle: "Vehicle"
        case .pet: "Pet"
        case .visitor: "Visitor"
        }
    }

    var symbol: String {
        switch self {
        case .motion: "figure.walk.motion"
        case .person: "person.fill"
        case .vehicle: "car.fill"
        case .pet: "pawprint.fill"
        case .visitor: "bell.fill"
        }
    }

    /// The key this detection has in the `ai` map of a `GetEvents` or
    /// `GetAiState` response. Motion and visitor are their own fields, not AI
    /// types, so they have none.
    var aiKey: String? {
        switch self {
        case .person: "people"
        case .vehicle: "vehicle"
        case .pet: "dog_cat"
        case .motion, .visitor: nil
        }
    }
}

/// Holds the latest motion, AI detection, and doorbell visitor state per
/// camera. `EventPoller` fills it in.
@MainActor
@Observable
final class EventStatusStore {
    /// What one camera reports, and which detections it reports at all.
    ///
    /// A camera that does not support a detection is not the same as one that
    /// supports it and sees nothing, so the two sets are kept apart. The strip
    /// draws a dot only for a supported detection.
    struct CameraEvents: Equatable, Sendable {
        var supported: Set<Detection> = []
        var active: Set<Detection> = []

        func supports(_ detection: Detection) -> Bool { supported.contains(detection) }

        func isActive(_ detection: Detection) -> Bool { active.contains(detection) }

        /// The supported detections in a stable order.
        var visible: [Detection] { Detection.allCases.filter(supported.contains) }
    }

    private(set) var byCameraID: [String: CameraEvents] = [:]

    func update(cameraID: String, events: CameraEvents) {
        byCameraID[cameraID] = events
    }

    func events(for cameraID: String) -> CameraEvents {
        byCameraID[cameraID] ?? CameraEvents()
    }

    func clear() {
        byCameraID = [:]
    }
}

extension EventStatusStore.CameraEvents {
    init(events response: GetEvents.Response) {
        // `md` omits `support` on the cameras that have it, so an absent
        // `support` counts as supported.
        if response.motion?.isSupported(whenAbsent: true) == true {
            insert(.motion, active: response.motionDetected)
        }
        if response.supportsVisitor {
            insert(.visitor, active: response.visitorDetected)
        }
        insertAI(supported: response.supportedAITypes, isDetected: response.aiDetected)
    }

    init(motion: GetMdState.Response, ai: GetAiState.Response?) {
        insert(.motion, active: motion.motionDetected)
        guard let ai else { return }
        insertAI(supported: ai.supportedAITypes, isDetected: ai.aiDetected)
    }

    private mutating func insertAI(supported keys: [String], isDetected: (String) -> Bool) {
        let keys = Set(keys)
        for detection in Detection.allCases {
            guard let key = detection.aiKey, keys.contains(key) else { continue }
            insert(detection, active: isDetected(key))
        }
    }

    private mutating func insert(_ detection: Detection, active isActive: Bool) {
        supported.insert(detection)
        if isActive { active.insert(detection) }
    }
}

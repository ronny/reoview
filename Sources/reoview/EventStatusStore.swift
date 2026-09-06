import Observation

/// Holds the latest motion and AI detection state per camera.
///
/// Milestone 5 adds the `EventPoller` that fills this in. Until then it stays
/// empty and the status strip shows every dot as off.
@MainActor
@Observable
final class EventStatusStore {
    struct CameraEvents: Equatable, Sendable {
        var motion = false
        var person = false
        var vehicle = false
        var visitor = false
    }

    private(set) var byCameraID: [String: CameraEvents] = [:]

    func update(cameraID: String, events: CameraEvents) {
        byCameraID[cameraID] = events
    }

    func events(for cameraID: String) -> CameraEvents {
        byCameraID[cameraID] ?? CameraEvents()
    }
}

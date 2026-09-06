import Foundation
import Observation

/// The persisted configuration. JSON in `UserDefaults`, carrying a schema
/// version. A decode error logs and falls back to a fresh default; it must
/// never stop the app from starting.
///
/// The password is never here. It lives in the keychain. See `KeychainStore`.
struct AppConfig: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var host: String
    var username: String

    /// `StreamSource` ids, in the order the grid shows them.
    var tileOrder: [String]

    /// Mute state per `StreamSource` id. Absent means muted.
    var mutedBySourceID: [String: Bool]

    /// The candidate URL that last played, per `StreamSource` id, with the
    /// credentials stripped out. Stripping keeps the password out of the
    /// defaults plist; `AppState` puts the credentials back when it matches a
    /// saved winner against a fresh candidate list.
    var winningURLBySourceID: [String: String]

    /// `NSStringFromRect` of the main window frame.
    var windowFrame: String?

    init(
        version: Int = AppConfig.currentVersion,
        host: String = "",
        username: String = "",
        tileOrder: [String] = [],
        mutedBySourceID: [String: Bool] = [:],
        winningURLBySourceID: [String: String] = [:],
        windowFrame: String? = nil
    ) {
        self.version = version
        self.host = host
        self.username = username
        self.tileOrder = tileOrder
        self.mutedBySourceID = mutedBySourceID
        self.winningURLBySourceID = winningURLBySourceID
        self.windowFrame = windowFrame
    }
}

extension AppConfig {
    /// Pure, so the fallback path can be tested without `UserDefaults`.
    static func decode(_ data: Data?) -> AppConfig {
        guard let data else { return AppConfig() }
        do {
            let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
            guard decoded.version == currentVersion else {
                Log.config.error(
                    "AppConfig schema version \(decoded.version, privacy: .public) is not \(currentVersion, privacy: .public); using defaults"
                )
                return AppConfig()
            }
            return decoded
        } catch {
            Log.config.error("AppConfig decode failed (\(String(describing: error), privacy: .public)); using defaults")
            return AppConfig()
        }
    }

    func encoded() -> Data? {
        do {
            return try JSONEncoder().encode(self)
        } catch {
            Log.config.error("AppConfig encode failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// Reads `AppConfig` once at launch and writes it back on every change.
@MainActor
@Observable
final class ConfigStore {
    static let defaultsKey = "AppConfig"

    var config: AppConfig {
        didSet {
            guard config != oldValue else { return }
            save()
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.config = AppConfig.decode(defaults.data(forKey: Self.defaultsKey))
    }

    private func save() {
        guard let data = config.encoded() else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

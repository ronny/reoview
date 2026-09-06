import Foundation
import Observation

/// How the grid arranges its tiles.
enum LayoutMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Adaptive columns, sized to the window width.
    case grid
    /// One column. Every tile is the full window width.
    case stacked
    /// One row. Every tile is the full available height.
    case columns

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grid: "Grid"
        case .stacked: "Stacked"
        case .columns: "Columns"
        }
    }

    var symbol: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .stacked: "rectangle.grid.1x2"
        case .columns: "rectangle.split.3x1"
        }
    }
}

/// Which of one camera's streams the grid shows.
enum StreamSelection: Hashable, Sendable, Codable {
    /// One tile per lens, sub quality where the lens has one. The grid of
    /// CONTEXT.md.
    case standard
    /// One tile per `StreamSource` the camera has.
    case all
    /// One tile, for this `StreamSource` id.
    case source(String)
}

extension StreamSelection {
    /// A `StreamSource` id is always `"<camera>/<lens>/<quality>"`, so the two
    /// sentinels below can never collide with one.
    private static let standardValue = "standard"
    private static let allValue = "all"

    private var encodedValue: String {
        switch self {
        case .standard: Self.standardValue
        case .all: Self.allValue
        case .source(let id): id
        }
    }

    private init(encodedValue: String) {
        switch encodedValue {
        case Self.standardValue: self = .standard
        case Self.allValue: self = .all
        default: self = .source(encodedValue)
        }
    }

    init(from decoder: any Decoder) throws {
        self.init(encodedValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(encodedValue)
    }
}

/// The persisted configuration. JSON in `UserDefaults`, carrying a schema
/// version. A decode error logs and falls back to a fresh default; it must
/// never stop the app from starting.
///
/// The password is never here. It lives in the keychain. See `KeychainStore`.
struct AppConfig: Codable, Equatable, Sendable {
    /// Version 2 added `layout` and `streamSelectionByCameraID`, and dropped
    /// the saved tile order, which is now derived from the selections.
    /// Version 3 added `uiScale`. Version 4 added `talkPhrases`.
    static let currentVersion = 4

    /// What a fresh install offers to say through the doorbell. A config
    /// written before version 4 has no phrases key at all and gets these; a
    /// version 4 config always writes the key, so an emptied list stays empty.
    static let defaultTalkPhrases = [
        "Hello, we will be with you in a moment.",
        "Please leave the parcel by the front door. Thank you.",
        "Sorry, we cannot come to the door right now.",
        "Thank you. Goodbye.",
    ]

    /// Under 0.8 the chrome is hard to read; over 2.0 the controls stop fitting
    /// a tile in the narrowest layout.
    static let uiScaleRange: ClosedRange<Double> = 0.8...2.0

    /// A hand-edited plist can hold anything, including a NaN.
    static func clampedUIScale(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, uiScaleRange.lowerBound), uiScaleRange.upperBound)
    }

    var version: Int
    var host: String
    var username: String

    /// Mute state per `StreamSource` id. Absent means muted.
    var mutedBySourceID: [String: Bool]

    /// The candidate URL that last played, per `StreamSource` id, with the
    /// credentials stripped out. Stripping keeps the password out of the
    /// defaults plist; `AppState` puts the credentials back when it matches a
    /// saved winner against a fresh candidate list.
    var winningURLBySourceID: [String: String]

    /// `NSStringFromRect` of the main window frame.
    var windowFrame: String?

    var layout: LayoutMode

    /// Which streams the grid shows, per `Camera.id`. Absent means `.standard`.
    var streamSelectionByCameraID: [String: StreamSelection]

    /// How much larger than macOS default the text and icons are drawn. See
    /// `UIScale` for why the app carries this itself.
    var uiScale: Double {
        didSet { uiScale = Self.clampedUIScale(uiScale) }
    }

    /// The phrases the doorbell can be made to speak, in the order they are
    /// offered. Edited in Settings.
    var talkPhrases: [String]

    init(
        version: Int = AppConfig.currentVersion,
        host: String = "",
        username: String = "",
        mutedBySourceID: [String: Bool] = [:],
        winningURLBySourceID: [String: String] = [:],
        windowFrame: String? = nil,
        layout: LayoutMode = .grid,
        streamSelectionByCameraID: [String: StreamSelection] = [:],
        uiScale: Double = 1,
        talkPhrases: [String] = AppConfig.defaultTalkPhrases
    ) {
        self.version = version
        self.host = host
        self.username = username
        self.mutedBySourceID = mutedBySourceID
        self.winningURLBySourceID = winningURLBySourceID
        self.windowFrame = windowFrame
        self.layout = layout
        self.streamSelectionByCameraID = streamSelectionByCameraID
        self.uiScale = Self.clampedUIScale(uiScale)
        self.talkPhrases = talkPhrases
    }

    enum CodingKeys: String, CodingKey {
        case version
        case host
        case username
        case mutedBySourceID
        case winningURLBySourceID
        case windowFrame
        case layout
        case streamSelectionByCameraID
        case uiScale
        case talkPhrases
    }

    /// Every field but the version is optional, so a config written by an older
    /// schema keeps its host, username, and saved winners instead of being
    /// thrown away. An unreadable `layout` degrades to the default rather than
    /// failing the whole decode.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        mutedBySourceID = try container.decodeIfPresent([String: Bool].self, forKey: .mutedBySourceID) ?? [:]
        winningURLBySourceID = try container
            .decodeIfPresent([String: String].self, forKey: .winningURLBySourceID) ?? [:]
        windowFrame = try container.decodeIfPresent(String.self, forKey: .windowFrame)
        layout = try container.decodeIfPresent(String.self, forKey: .layout)
            .flatMap(LayoutMode.init(rawValue:)) ?? .grid
        streamSelectionByCameraID = try container
            .decodeIfPresent([String: StreamSelection].self, forKey: .streamSelectionByCameraID) ?? [:]
        uiScale = Self.clampedUIScale(try container.decodeIfPresent(Double.self, forKey: .uiScale) ?? 1)
        talkPhrases = try container
            .decodeIfPresent([String].self, forKey: .talkPhrases) ?? Self.defaultTalkPhrases
    }
}

extension AppConfig {
    /// Pure, so the fallback path can be tested without `UserDefaults`.
    static func decode(_ data: Data?) -> AppConfig {
        guard let data else { return AppConfig() }
        do {
            var decoded = try JSONDecoder().decode(AppConfig.self, from: data)
            guard (1...currentVersion).contains(decoded.version) else {
                Log.config.error(
                    "AppConfig schema version \(decoded.version, privacy: .public) is not known; using defaults"
                )
                return AppConfig()
            }
            decoded.version = currentVersion
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

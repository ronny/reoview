import OSLog

enum Log {
    static let subsystem = "au.ronny.ReolinkViewer"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let config = Logger(subsystem: subsystem, category: "config")
    static let keychain = Logger(subsystem: subsystem, category: "keychain")
    static let player = Logger(subsystem: subsystem, category: "player")
    static let presence = Logger(subsystem: subsystem, category: "presence")
}

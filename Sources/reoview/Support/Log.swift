import OSLog

enum Log {
    static let subsystem = "au.ronny.ReoView"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let config = Logger(subsystem: subsystem, category: "config")
    static let controls = Logger(subsystem: subsystem, category: "controls")
    static let events = Logger(subsystem: subsystem, category: "events")
    static let keychain = Logger(subsystem: subsystem, category: "keychain")
    static let player = Logger(subsystem: subsystem, category: "player")
    static let presence = Logger(subsystem: subsystem, category: "presence")
    static let talk = Logger(subsystem: subsystem, category: "talk")
}

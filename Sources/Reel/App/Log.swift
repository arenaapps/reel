import os

enum Log {
    static let app = Logger(subsystem: "com.arenaapps.reel", category: "app")
    static let render = Logger(subsystem: "com.arenaapps.reel", category: "render")
    static let record = Logger(subsystem: "com.arenaapps.reel", category: "record")
}

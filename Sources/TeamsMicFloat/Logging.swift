import Foundation
import os

enum Log {
    static let logger = Logger(subsystem: "com.local.teamsmicfloat", category: "app")
    static var verbose = false

    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func debug(_ message: String) {
        guard verbose else { return }
        write("DEBUG", message)
        logger.debug("\(message, privacy: .public)")
    }

    static func info(_ message: String) {
        write("INFO", message)
        logger.info("\(message, privacy: .public)")
    }

    static func warn(_ message: String) {
        write("WARN", message)
        logger.warning("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        write("ERROR", message)
        logger.error("\(message, privacy: .public)")
    }

    private static func write(_ level: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) \(level) \(message)\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}

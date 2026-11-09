import Foundation

struct StoredWindowPosition: Codable, Equatable {
    var x: Int
    var y: Int
}

enum FloatingWindowMode: String, Codable, Equatable {
    case hidden
    case inCallOnly
    case always
}

struct AppConfig: Codable {
    var version: Int = 1
    var token: String?
    var autoPair: Bool = true
    var window: StoredWindowPosition?
    var floatingWindowMode: FloatingWindowMode = .hidden
    var updatedAt: String?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version
        case token
        case autoPair
        case window
        case floatingWindowMode
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        token = try? container.decodeIfPresent(String.self, forKey: .token)
        autoPair = (try? container.decodeIfPresent(Bool.self, forKey: .autoPair)) ?? true
        window = try? container.decodeIfPresent(StoredWindowPosition.self, forKey: .window)
        floatingWindowMode = (try? container.decodeIfPresent(FloatingWindowMode.self, forKey: .floatingWindowMode)) ?? .hidden
        updatedAt = try? container.decodeIfPresent(String.self, forKey: .updatedAt)
    }
}

enum ConfigError: Error, LocalizedError {
    case cannotCreateDirectory(String)
    case cannotRead(String)
    case cannotWrite(String)

    var errorDescription: String? {
        switch self {
        case .cannotCreateDirectory(let message):
            return "Could not create the config directory: \(message)"
        case .cannotRead(let message):
            return "Could not read config.json: \(message)"
        case .cannotWrite(let message):
            return "Could not write config.json: \(message)"
        }
    }
}

final class ConfigStore {
    let url: URL
    private var config = AppConfig()
    private let lock = NSLock()

    init(url: URL) throws {
        self.url = url
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ConfigError.cannotCreateDirectory(error.localizedDescription)
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        load()
    }

    var path: String { url.path }

    var token: String? {
        lock.lock()
        defer { lock.unlock() }
        return config.token
    }

    var hasToken: Bool { token != nil }

    var autoPair: Bool {
        lock.lock()
        defer { lock.unlock() }
        return config.autoPair
    }

    func windowPosition() -> StoredWindowPosition? {
        lock.lock()
        defer { lock.unlock() }
        return config.window
    }

    var floatingWindowMode: FloatingWindowMode {
        lock.lock()
        defer { lock.unlock() }
        return config.floatingWindowMode
    }

    func setFloatingWindowMode(_ mode: FloatingWindowMode) throws {
        lock.lock()
        defer { lock.unlock() }
        config.floatingWindowMode = mode
        try saveLocked()
    }

    func setToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidToken(trimmed) else {
            throw ConfigError.cannotWrite("Teams returned an invalid pairing token")
        }
        lock.lock()
        defer { lock.unlock() }
        config.token = trimmed
        try saveLocked()
    }

    func clearToken() throws {
        lock.lock()
        defer { lock.unlock() }
        config.token = nil
        try saveLocked()
    }

    func setAutoPair(_ enabled: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        config.autoPair = enabled
        try saveLocked()
    }

    func setWindowPosition(x: Int, y: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        config.window = StoredWindowPosition(x: x, y: y)
        try saveLocked()
    }

    // MARK: - Private

    private func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            var decoded = try JSONDecoder().decode(AppConfig.self, from: data)
            if let token = decoded.token, !Self.isValidToken(token) {
                Log.warn("Ignoring an invalid token in \(url.lastPathComponent)")
                decoded.token = nil
            }
            config = decoded
            tightenPermissions()
        } catch {
            Log.warn("Invalid config.json (\(error.localizedDescription)); moving it aside")
            let stamp = ISO8601DateFormatter()
                .string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
            try? FileManager.default.moveItem(at: url, to: backup)
        }
    }

    private func saveLocked() throws {
        config.version = 1
        config.updatedAt = ISO8601DateFormatter().string(from: Date())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: url, options: [.atomic])
            if let handle = try? FileHandle(forWritingTo: url) {
                try? handle.synchronize()
                try? handle.close()
            }
            tightenPermissions()
        } catch {
            throw ConfigError.cannotWrite(error.localizedDescription)
        }
    }

    private func tightenPermissions() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
        if mode & 0o077 != 0 {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
    }

    private static func isValidToken(_ token: String) -> Bool {
        !token.isEmpty
            && token.count <= 4096
            && !token.contains("\n")
            && !token.contains("\r")
            && !token.contains("\0")
    }
}

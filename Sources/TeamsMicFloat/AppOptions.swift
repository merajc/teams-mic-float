import Foundation

struct AppOptions {
    static let version = "1.0.0"

    var configURL: URL
    var debug: Bool = false
    var showHelp: Bool = false
    var showVersion: Bool = false

    static func parse(arguments: [String]) throws -> AppOptions {
        let environment = ProcessInfo.processInfo.environment
        let defaultConfig = environment["TEAMS_FLOAT_CONFIG"].map {
            URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)
        } ?? Self.defaultConfigURL()

        var options = AppOptions(configURL: defaultConfig)
        var index = 1

        func nextValue(for flag: String) throws -> String {
            index += 1
            guard index < arguments.count else {
                throw AppOptionsError.missingValue(flag)
            }
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                options.showHelp = true
            case "--version":
                options.showVersion = true
            case "--config":
                let value = try nextValue(for: "--config")
                options.configURL = URL(
                    fileURLWithPath: NSString(string: value).expandingTildeInPath
                )
            case "--debug":
                options.debug = true
            default:
                if argument.hasPrefix("-") {
                    throw AppOptionsError.unknownFlag(argument)
                }
                // Finder may pass a stray argument when opening the bundle.
                Log.warn("Ignoring unexpected argument: \(argument)")
            }
            index += 1
        }
        return options
    }

    static func defaultConfigURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base
            .appendingPathComponent("TeamsMicFloat", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
    }

    static func usage() -> String {
        """
        Teams Mic Float \(version) — native macOS Teams microphone button

        Usage:
          TeamsMicFloat [options]

        Options:
          --config PATH       JSON file used for the saved window position
          --debug             Verbose logging to stderr
          --version           Print the version
          -h, --help          Show this help

        Environment:
          TEAMS_FLOAT_CONFIG  Override the config.json path

        macOS Accessibility permission is required. The app controls Teams by
        reading and pressing its microphone button through the AX API.
        """
    }
}

enum AppOptionsError: Error, LocalizedError {
    case missingValue(String)
    case invalidValue(String, String)
    case unknownFlag(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let flag):
            return "Missing value for \(flag)"
        case .invalidValue(let flag, let value):
            return "Invalid value for \(flag): \(value)"
        case .unknownFlag(let flag):
            return "Unknown option: \(flag)"
        }
    }
}

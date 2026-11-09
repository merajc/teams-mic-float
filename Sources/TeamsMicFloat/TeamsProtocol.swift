import Foundation

enum ConnectionPhase: String, Equatable {
    case disconnected
    case connecting
    case connected
}

struct ClientState: Equatable {
    var phase: ConnectionPhase = .disconnected
    var connected = false
    var paired = false
    var pairingRequired = false
    var inMeeting = false
    var muted = false
    var muteKnown = false
    var canToggleMute = false
    var canPair = false
    var detail = "Starting"
    var lastError: String?
    var retryIn: Int?
    var requiresAccessibility = false

    var canToggle: Bool {
        connected && inMeeting && canToggleMute
    }
}

enum NoticeLevel: String {
    case info
    case success
    case warning
    case error
}

struct Notice {
    var title: String
    var message: String
    var level: NoticeLevel = .info
}

struct MeetingPatch: Equatable {
    var isMuted: Bool?
    var isInMeeting: Bool?
    var canToggleMute: Bool?
    var canPair: Bool?

    var isEmpty: Bool {
        isMuted == nil && isInMeeting == nil && canToggleMute == nil && canPair == nil
    }
}

struct ServerMessage: Equatable {
    var meeting: MeetingPatch?
    var tokenRefresh: String?
    var requestId: Int?
    var response: String?
    var error: String?
}

enum ProtocolError: Error, LocalizedError {
    case invalidJSON
    case nonObject
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Teams sent invalid JSON"
        case .nonObject:
            return "Teams sent a non-object JSON frame"
        case .encodingFailed:
            return "Could not encode the Teams command"
        }
    }
}

enum TeamsProtocol {
    static let version = "2.0.0"

    static func buildURL(
        host: String = "127.0.0.1",
        port: Int = 8124,
        token: String? = nil,
        manufacturer: String = "TeamsMicFloat",
        device: String = "FloatingButton",
        app: String = "Teams Mic Float",
        appVersion: String = "1.0.0"
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "ws"
        var bareHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if bareHost.hasPrefix("["), bareHost.hasSuffix("]") {
            bareHost.removeFirst()
            bareHost.removeLast()
        }
        if bareHost.contains(":") {
            bareHost = "[\(bareHost)]"
        }
        components.host = bareHost
        components.port = port
        components.path = "/"

        var items: [URLQueryItem] = []
        if let token, !token.isEmpty {
            items.append(URLQueryItem(name: "token", value: token))
        }
        items.append(URLQueryItem(name: "protocol-version", value: version))
        items.append(URLQueryItem(name: "manufacturer", value: manufacturer))
        items.append(URLQueryItem(name: "device", value: device))
        items.append(URLQueryItem(name: "app", value: app))
        items.append(URLQueryItem(name: "app-version", value: appVersion))
        components.queryItems = items
        return components.url
    }

    static func actionFrame(
        action: String,
        parameters: [String: Any] = [:],
        requestId: Int
    ) throws -> String {
        let object: [String: Any] = [
            "action": action,
            "parameters": parameters,
            "requestId": requestId,
        ]
        guard
            JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object, options: []),
            let text = String(data: data, encoding: .utf8)
        else {
            throw ProtocolError.encodingFailed
        }
        return text
    }

    static func parse(_ text: String) throws -> ServerMessage {
        guard let data = text.data(using: .utf8) else {
            throw ProtocolError.invalidJSON
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ProtocolError.invalidJSON
        }
        guard let payload = object as? [String: Any] else {
            throw ProtocolError.nonObject
        }

        var message = ServerMessage()
        message.requestId = integer(value(payload, "requestId", "request_id"))
        message.response = string(value(payload, "response", "result"))
        message.error = string(value(payload, "errorMsg", "errorMessage", "error_msg", "error"))
        message.tokenRefresh = string(
            value(payload, "tokenRefresh", "token_refresh", "refreshToken")
        )

        var patch = MeetingPatch()
        var hasMeetingFields = false

        if let update = dictionary(value(payload, "meetingUpdate", "meeting_update")) {
            var state = dictionary(value(update, "meetingState", "meeting_state", "state")) ?? update
            if state.isEmpty {
                state = update
            }
            let permissions =
                dictionary(value(update, "meetingPermissions", "meeting_permissions", "permissions"))
                ?? [:]

            if let muted = boolean(value(state, "isMuted", "is_muted", "muted")) {
                patch.isMuted = muted
                hasMeetingFields = true
            }
            if let inMeeting = boolean(
                value(state, "isInMeeting", "is_in_meeting", "inMeeting", "in_meeting")
            ) {
                patch.isInMeeting = inMeeting
                hasMeetingFields = true
            }
            if let canToggle = boolean(value(permissions, "canToggleMute", "can_toggle_mute")) {
                patch.canToggleMute = canToggle
                hasMeetingFields = true
            }
            if let canPair = boolean(value(permissions, "canPair", "can_pair")) {
                patch.canPair = canPair
                hasMeetingFields = true
            }
        }

        if let muteUpdate = dictionary(value(payload, "muteStateUpdate", "mute_state_update")) {
            if let muted = boolean(value(muteUpdate, "isMuted", "is_muted", "muted")) {
                patch.isMuted = muted
                hasMeetingFields = true
            }
            if let inMeeting = boolean(
                value(muteUpdate, "isInMeeting", "is_in_meeting", "inMeeting")
            ) {
                patch.isInMeeting = inMeeting
                hasMeetingFields = true
            }
            if let canToggle = boolean(
                value(muteUpdate, "canToggleMute", "can_toggle_mute")
            ) {
                patch.canToggleMute = canToggle
                hasMeetingFields = true
            }
        }

        // Defensive support for a flat notification shape.
        if !hasMeetingFields, value(payload, "isMuted", "is_muted") != nil {
            patch.isMuted = boolean(value(payload, "isMuted", "is_muted"))
            patch.isInMeeting = boolean(value(payload, "isInMeeting", "is_in_meeting"))
            hasMeetingFields = !patch.isEmpty
        }

        if hasMeetingFields {
            message.meeting = patch
        }
        return message
    }

    // MARK: - JSON helpers

    private static func normalise(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func value(_ dictionary: [String: Any], _ names: String...) -> Any? {
        var normalised: [String: Any] = [:]
        for (key, item) in dictionary {
            normalised[normalise(key)] = item
        }
        for name in names {
            if let result = normalised[normalise(name)] {
                return result
            }
        }
        return nil
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func boolean(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "1", "yes", "on":
                return true
            case "false", "0", "no", "off":
                return false
            default:
                return nil
            }
        }
        return nil
    }
}

// MARK: - UI state mapping

enum VisualState: String, CaseIterable {
    case muted
    case unmuted
    case idle
    case offline
    case connecting
    case pairing
    case syncing
    case permission

    static func from(_ state: ClientState) -> VisualState {
        if state.phase == .connecting {
            return .connecting
        }
        if state.requiresAccessibility {
            return .permission
        }
        if !state.connected {
            return .offline
        }
        if state.pairingRequired {
            return .pairing
        }
        if !state.inMeeting {
            return .idle
        }
        if !state.muteKnown {
            return .syncing
        }
        return state.muted ? .muted : .unmuted
    }

    var label: String {
        switch self {
        case .muted: return "MUTED"
        case .unmuted: return "UNMUTED"
        case .idle: return "IDLE"
        case .offline: return "OFFLINE"
        case .connecting: return "LINKING"
        case .pairing: return "PAIR"
        case .syncing: return "SYNC"
        case .permission: return "ACCESS"
        }
    }

    var caption: String {
        switch self {
        case .muted, .unmuted: return "IN CALL"
        case .idle: return "NO CALL"
        case .offline: return "NO TEAMS"
        case .connecting: return "CONNECTING"
        case .pairing: return "IN TEAMS"
        case .syncing: return "IN CALL"
        case .permission: return "PERMISSION"
        }
    }

    var palette: Palette {
        switch self {
        case .muted:
            return Palette(
                ring: "#FF4D5E",
                fillTop: "#4A0D17",
                fillBottom: "#24060C",
                glow: "#7F1D2D",
                icon: "#FFE4E6",
                dot: "#FF4D5E"
            )
        case .unmuted:
            return Palette(
                ring: "#35E08C",
                fillTop: "#093A2A",
                fillBottom: "#041C14",
                glow: "#0F5F45",
                icon: "#ECFDF5",
                dot: "#35E08C"
            )
        case .idle:
            return Palette(
                ring: "#5B6B82",
                fillTop: "#172233",
                fillBottom: "#0B111A",
                glow: "#243247",
                icon: "#AAB7C8",
                dot: "#64748B"
            )
        case .offline:
            return Palette(
                ring: "#475569",
                fillTop: "#121C2A",
                fillBottom: "#080D15",
                glow: "#1E293B",
                icon: "#6B7C93",
                dot: "#475569"
            )
        case .connecting:
            return Palette(
                ring: "#F3B24A",
                fillTop: "#3A2608",
                fillBottom: "#1A1003",
                glow: "#7A5516",
                icon: "#FDE7B2",
                dot: "#F3B24A"
            )
        case .pairing:
            return Palette(
                ring: "#FBBF24",
                fillTop: "#3B2806",
                fillBottom: "#1B1202",
                glow: "#7A5516",
                icon: "#FFF3C4",
                dot: "#FBBF24"
            )
        case .syncing:
            return Palette(
                ring: "#7C8DA5",
                fillTop: "#1A2838",
                fillBottom: "#0B121B",
                glow: "#2A3A50",
                icon: "#C2CEDD",
                dot: "#7C8DA5"
            )
        case .permission:
            return Palette(
                ring: "#FBBF24",
                fillTop: "#3B2806",
                fillBottom: "#1B1202",
                glow: "#7A5516",
                icon: "#FFF3C4",
                dot: "#FBBF24"
            )
        }
    }

    func statusTitle(_ state: ClientState) -> String {
        switch self {
        case .connecting:
            return "Connecting to Teams"
        case .offline:
            if let retry = state.retryIn {
                return "Teams offline — retrying in \(retry)s"
            }
            return "Teams offline"
        case .pairing:
            return "Pairing required"
        case .muted:
            return "In call — muted"
        case .unmuted:
            return "In call — unmuted"
        case .syncing:
            return "In call — syncing"
        case .idle:
            return "Not in a call"
        case .permission:
            return "Accessibility permission required"
        }
    }

    func statusHint(_ state: ClientState) -> String {
        switch self {
        case .connecting:
            return "Waiting for the local Teams API"
        case .offline:
            return "Click to retry now"
        case .pairing:
            return "Approve the request inside Teams"
        case .muted:
            return "Click to unmute"
        case .unmuted:
            return "Click to mute"
        case .syncing:
            return "Waiting for microphone state"
        case .idle:
            return "Click for connection options"
        case .permission:
            return "Open System Settings → Privacy & Security → Accessibility"
        }
    }
}

struct Palette {
    let ring: String
    let fillTop: String
    let fillBottom: String
    let glow: String
    let icon: String
    let dot: String
}

import AppKit
import Darwin
import Foundation

@main
struct TestHarness {
    @MainActor
    static func main() async {
        _ = NSApplication.shared
        let assertions = Assertions()

        do {
            try runProtocolTests(assertions)
            try runConfigTests(assertions)
            runVisualTests(assertions)
            runClickTests(assertions)
            await runLiveClientTests(assertions)
        } catch {
            assertions.fail("Unexpected error: \(error)")
        }

        print("")
        if assertions.failures == 0 {
            print("PASS — \(assertions.checks) checks")
            exit(0)
        } else {
            print("FAIL — \(assertions.failures) failure(s) out of \(assertions.checks) checks")
            exit(1)
        }
    }

    // MARK: - Protocol

    static func runProtocolTests(_ t: Assertions) throws {
        let url = try unwrap(TeamsProtocol.buildURL(port: 8124), "build URL")
        let components = try unwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false),
            "URL components"
        )
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        t.expect(url.scheme == "ws", "WebSocket scheme")
        t.expect(url.host == "127.0.0.1", "WebSocket host")
        t.expect(url.port == 8124, "WebSocket port")
        t.expect(query["token"] == nil, "first connection omits token")
        t.expect(query["protocol-version"] == "2.0.0", "protocol-version is 2.0.0")

        let tokenURL = try unwrap(
            TeamsProtocol.buildURL(
                token: "a b&c",
                manufacturer: "Acme Corp",
                device: "Desk/Button",
                app: "Mic Float",
                appVersion: "1.2.3"
            ),
            "token URL"
        )
        let tokenComponents = try unwrap(
            URLComponents(url: tokenURL, resolvingAgainstBaseURL: false),
            "token components"
        )
        let tokenQuery = Dictionary(
            uniqueKeysWithValues: (tokenComponents.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            }
        )
        t.expect(tokenQuery["token"] == "a b&c", "token is encoded and preserved")
        t.expect(tokenQuery["manufacturer"] == "Acme Corp", "manufacturer is encoded")
        t.expect(!tokenURL.absoluteString.contains("a b&c"), "raw token is not present")

        let ipv6 = try unwrap(TeamsProtocol.buildURL(host: "[::1]"), "IPv6 URL")
        t.expect(ipv6.absoluteString.hasPrefix("ws://[::1]:8124"), "IPv6 host is bracketed")

        let full = try TeamsProtocol.parse(
            #"{"meetingUpdate":{"meetingState":{"isMuted":true,"isInMeeting":true},"meetingPermissions":{"canToggleMute":true,"canPair":false}}}"#
        )
        let meeting = try unwrap(full.meeting, "meeting patch")
        t.expect(meeting.isMuted == true, "parses isMuted")
        t.expect(meeting.isInMeeting == true, "parses isInMeeting")
        t.expect(meeting.canToggleMute == true, "parses canToggleMute")
        t.expect(meeting.canPair == false, "parses canPair")

        let snake = try TeamsProtocol.parse(
            #"{"mute_state_update":{"is_muted":true,"is_in_meeting":true,"can_toggle_mute":true}}"#
        )
        t.expect(snake.meeting?.isMuted == true, "parses snake_case mute update")

        let flat = try TeamsProtocol.parse(#"{"isMuted":false,"isInMeeting":true}"#)
        t.expect(flat.meeting?.isMuted == false, "parses flat mute update")
        t.expect(flat.meeting?.isInMeeting == true, "parses flat meeting update")

        let refresh = try TeamsProtocol.parse(#"{"tokenRefresh":"abc-123"}"#)
        t.expect(refresh.tokenRefresh == "abc-123", "parses tokenRefresh")

        let response = try TeamsProtocol.parse(#"{"requestId":4,"response":"Success"}"#)
        t.expect(response.requestId == 4, "parses requestId")
        t.expect(response.response == "Success", "parses response")

        let error = try TeamsProtocol.parse(#"{"requestId":5,"errorMsg":"no active call"}"#)
        t.expect(error.error == "no active call", "parses errorMsg")

        t.expectThrows("rejects malformed JSON") {
            _ = try TeamsProtocol.parse("{not-json")
        }
        t.expectThrows("rejects non-object JSON") {
            _ = try TeamsProtocol.parse("[]")
        }

        let frame = try TeamsProtocol.actionFrame(
            action: "toggle-mute",
            parameters: [:],
            requestId: 7
        )
        let object = try unwrap(
            JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any],
            "action frame JSON"
        )
        t.expect(object["action"] as? String == "toggle-mute", "action frame action")
        t.expect(object["requestId"] as? Int == 7, "action frame requestId")
    }

    // MARK: - Config

    static func runConfigTests(_ t: Assertions) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TeamsMicFloatHarness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("config.json")
        let config = try ConfigStore(url: url)
        t.expect(!config.hasToken, "config starts unpaired")
        try config.setToken("  token-123  ")
        t.expect(config.token == "token-123", "token is trimmed and saved")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        t.expect(
            (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
            "config.json is owner-only (0600)"
        )

        let reloaded = try ConfigStore(url: url)
        t.expect(reloaded.token == "token-123", "token survives reload")
        try reloaded.setWindowPosition(x: 42, y: 84)
        try reloaded.clearToken()
        let afterClear = try ConfigStore(url: url)
        t.expect(afterClear.token == nil, "clearToken removes token")
        t.expect(
            afterClear.windowPosition() == StoredWindowPosition(x: 42, y: 84),
            "window position survives token clear"
        )
        t.expect(afterClear.floatingWindowMode == .hidden, "default floatingWindowMode is hidden")
        try afterClear.setFloatingWindowMode(.always)
        let reloadedMode = try ConfigStore(url: url)
        t.expect(reloadedMode.floatingWindowMode == .always, "floatingWindowMode persists")

        t.expectThrows("rejects token containing newline") {
            try afterClear.setToken("bad\nvalue")
        }
        t.expectThrows("rejects empty token") {
            try afterClear.setToken("")
        }

        let loose = directory.appendingPathComponent("loose.json")
        try #"{"token":"abc"}"#.write(to: loose, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: loose.path
        )
        _ = try ConfigStore(url: loose)
        let looseAttributes = try FileManager.default.attributesOfItem(atPath: loose.path)
        t.expect(
            (looseAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
            "loose config permissions are repaired"
        )

        let corrupt = directory.appendingPathComponent("corrupt.json")
        try "{broken".write(to: corrupt, atomically: true, encoding: .utf8)
        _ = try ConfigStore(url: corrupt)
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("corrupt.json.corrupt-") }
        t.expect(backups.count == 1, "corrupt config is preserved as a backup")
    }

    // MARK: - Visual and click

    static func runVisualTests(_ t: Assertions) {
        var state = ClientState()
        t.expect(VisualState.from(state) == .offline, "offline visual")
        state.phase = .connecting
        t.expect(VisualState.from(state) == .connecting, "connecting visual")
        state.phase = .connected
        state.connected = true
        t.expect(VisualState.from(state) == .idle, "idle visual")
        state.inMeeting = true
        t.expect(VisualState.from(state) == .syncing, "syncing visual")
        state.muteKnown = true
        state.muted = false
        t.expect(VisualState.from(state) == .unmuted, "unmuted visual")
        state.muted = true
        t.expect(VisualState.from(state) == .muted, "muted visual")
        state.pairingRequired = true
        t.expect(VisualState.from(state) == .pairing, "pairing visual")

        var permission = ClientState()
        permission.requiresAccessibility = true
        t.expect(VisualState.from(permission) == .permission, "permission visual")
        t.expect(VisualState.permission.label == "ACCESS", "permission label")

        t.expect(TeamsAccessibilityMatcher.isMicrophoneElement(
            role: "AXButton",
            domID: "microphone-button",
            title: "",
            description: ""
        ), "AX microphone DOM id matches")
        t.expect(TeamsAccessibilityMatcher.isMicrophoneElement(
            role: "AXButton",
            domID: "",
            title: "Mute mic",
            description: "Mute mic"
        ), "AX microphone label fallback matches")
        t.expect(TeamsAccessibilityMatcher.isMuted(
            title: "Unmute mic",
            description: "Unmute mic"
        ) == true, "Unmute label means currently muted")
        t.expect(TeamsAccessibilityMatcher.isMuted(
            title: "Mute mic",
            description: "Mute mic"
        ) == false, "Mute label means currently unmuted")
        t.expect(TeamsAccessibilityMatcher.isMuted(
            title: "Mic",
            description: "Mic"
        ) == nil, "generic Mic label is unknown")
        t.expect(TeamsAccessibilityMatcher.isMeetingWindow(
            title: "Meeting compact view | Meeting with Meraj",
            subrole: "AXSystemDialog"
        ), "compact meeting window matches")
        t.expect(!TeamsAccessibilityMatcher.isMeetingWindow(
            title: "Chat | Dis-Chem Pharmacies",
            subrole: "AXStandardWindow"
        ), "chat window is not a meeting")

        t.expect(VisualState.muted.label == "MUTED", "muted label")
        t.expect(VisualState.unmuted.label == "UNMUTED", "unmuted label")
        t.expect(VisualState.offline.caption == "NO TEAMS", "offline caption")
        t.expect(VisualState.muted.palette.ring == "#FF4D5E", "muted ring is red")
        t.expect(VisualState.unmuted.palette.ring == "#35E08C", "unmuted ring is green")
    }

    static func runClickTests(_ t: Assertions) {
        let view = StatusView(frame: NSRect(x: 0, y: 0, width: 124, height: 124))
        var clicks = 0
        view.onPrimary = { clicks += 1 }
        var state = ClientState()
        state.phase = .connected
        state.connected = true
        state.inMeeting = true
        state.muteKnown = true
        state.muted = true
        view.update(state: state)

        guard
            let down = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: NSPoint(x: 62, y: 62),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            ),
            let up = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: NSPoint(x: 62, y: 62),
                modifierFlags: [],
                timestamp: 0.01,
                windowNumber: 0,
                context: nil,
                eventNumber: 2,
                clickCount: 1,
                pressure: 0
            )
        else {
            t.fail("could not create mouse events")
            return
        }
        view.mouseDown(with: down)
        view.mouseUp(with: up)
        t.expect(clicks == 1, "click invokes primary action exactly once")
    }

    // MARK: - Live WebSocket test

    @MainActor
    static func runLiveClientTests(_ t: Assertions) async {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let serverScript = root.appendingPathComponent("tools/mock_teams_server.py")
        guard FileManager.default.fileExists(atPath: serverScript.path) else {
            t.fail("mock server not found at \(serverScript.path)")
            return
        }

        let port = Int.random(in: 22000...52000)
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("TeamsMicFloatLive-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        } catch {
            t.fail("could not create live-test directory: \(error)")
            return
        }
        defer { try? FileManager.default.removeItem(at: temp) }

        var server: Process?
        func startServer() throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "python3", "-u", serverScript.path,
                "--port", String(port),
                "--state", "in-call",
                "--no-console",
            ]
            process.currentDirectoryURL = root
            let logURL = temp.appendingPathComponent("mock.log")
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            return process
        }

        do {
            server = try startServer()
        } catch {
            t.fail("could not start mock server: \(error)")
            return
        }
        defer {
            if let server, server.isRunning {
                server.terminate()
                server.waitUntilExit()
            }
        }

        try? await Task.sleep(nanoseconds: 700_000_000)

        let configURL = temp.appendingPathComponent("config.json")
        let config: ConfigStore
        do {
            config = try ConfigStore(url: configURL)
        } catch {
            t.fail("could not create live config: \(error)")
            return
        }

        var options = TeamsClient.Options()
        options.port = port
        options.autoPairOverride = true
        options.reconnectDelays = [0.3, 0.5]
        options.pairingDelay = 0.25
        options.pairingRetry = 1
        options.heartbeatInterval = 2
        options.openTimeout = 2

        let client = TeamsClient(config: config, options: options)
        let history = StateHistory()
        client.onState = { state in
            history.states.append(state)
        }
        client.start()

        let paired = await waitUntil(timeout: 12) {
            client.state.canToggle && config.token != nil
        }
        t.expect(paired, "live client pairs and can toggle mute")
        t.expect(client.state.inMeeting, "live client reports in meeting")
        t.expect(VisualState.from(client.state) == .unmuted, "live unmuted visual")
        t.expect(config.token != nil, "pairing token was persisted")

        if paired {
            let firstToggle = await client.toggleMute()
            let becameMuted = await waitUntil(timeout: 4) { client.state.muted }
            t.expect(firstToggle, "toggle-mute command sent")
            t.expect(becameMuted, "muted state broadcast updates UI immediately")
            t.expect(VisualState.from(client.state) == .muted, "live muted visual")

            let secondToggle = await client.toggleMute()
            let becameUnmuted = await waitUntil(timeout: 4) {
                client.state.muteKnown && !client.state.muted
            }
            t.expect(secondToggle, "second toggle command sent")
            t.expect(becameUnmuted, "unmuted state broadcast updates UI immediately")

            history.states.removeAll()
            client.reconnect()
            let reconnected = await waitUntil(timeout: 8) {
                client.state.connected && client.state.canToggle
            }
            let sawDisconnect = history.states.contains { !$0.connected }
            t.expect(reconnected, "client reconnects after a manual drop")
            t.expect(sawDisconnect, "reconnect transition passes through disconnected")
        }

        await client.stop()
        if let server, server.isRunning {
            server.terminate()
            server.waitUntilExit()
        }
        server = nil
    }

    @MainActor
    static func waitUntil(
        timeout: TimeInterval,
        _ predicate: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate()
    }

    static func unwrap<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else {
            throw HarnessError.unwrapFailed(label)
        }
        return value
    }
}

@MainActor
final class StateHistory {
    var states: [ClientState] = []
}

enum HarnessError: Error {
    case unwrapFailed(String)
}

final class Assertions {
    private(set) var failures = 0
    private(set) var checks = 0

    func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        if condition() {
            print("  ok   \(label)")
        } else {
            failures += 1
            print("  FAIL \(label)")
        }
    }

    func expectThrows(_ label: String, _ body: () throws -> Void) {
        checks += 1
        do {
            try body()
            failures += 1
            print("  FAIL \(label)")
        } catch {
            print("  ok   \(label)")
        }
    }

    func fail(_ label: String) {
        checks += 1
        failures += 1
        print("  FAIL \(label)")
    }
}

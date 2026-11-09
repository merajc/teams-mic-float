import AppKit
import ApplicationServices

/// Controls Teams through its macOS Accessibility tree.
///
/// Microsoft removed the local WebSocket API in 2026.  The current Teams client
/// still exposes its WebView UI through AX, including a button whose stable
/// DOM identifier is `microphone-button`.  MuteMe uses the same general
/// approach.  Reading the button label provides two-way state; AXPress provides
/// control.
final class TeamsAccessibilityController: @unchecked Sendable {
    var onState: ((ClientState) -> Void)?
    var onNotice: ((Notice) -> Void)?

    private let queue = DispatchQueue(
        label: "com.local.teamsmicfloat.accessibility",
        qos: .utility
    )
    private let stateLock = NSLock()

    private var internalState = ClientState(
        phase: .disconnected,
        detail: "Starting"
    )
    private var timer: DispatchSourceTimer?
    private var running = false
    private var permissionPrompted = false
    private var permissionNoticeShown = false
    private var teamsPID: pid_t?
    private var teamsAX: AXUIElement?
    private var microphoneElement: AXUIElement?
    private var lastPress = Date.distantPast

    var state: ClientState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return internalState
    }

    // MARK: - Lifecycle

    func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            Log.info("Starting Teams Accessibility controller")
            self.startTimer()
            self.tick()
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.running = false
                self.timer?.cancel()
                self.timer = nil
                self.microphoneElement = nil
                self.teamsAX = nil
                self.teamsPID = nil
                continuation.resume()
            }
        }
    }

    func reconnect() {
        queue.async {
            self.microphoneElement = nil
            self.teamsAX = nil
            self.teamsPID = nil
            self.tick()
        }
    }

    func requestPrimaryAction() {
        queue.async {
            self.performPrimaryAction()
        }
    }

    func openAccessibilitySettings() {
        promptForAccessibility()
        let majors = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let destination = majors >= 27
            ? "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
            : "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        guard let url = URL(string: destination) else { return }
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Polling

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(150),
            leeway: .milliseconds(50)
        )
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        self.timer = timer
        timer.resume()
    }

    private func tick() {
        guard running else { return }

        guard AXIsProcessTrusted() else {
            microphoneElement = nil
            teamsAX = nil
            teamsPID = nil
            var permissionState = ClientState(
                phase: .disconnected,
                connected: false,
                detail: "Accessibility permission required",
                lastError: "Enable Teams Mic Float in System Settings → Privacy & Security → Accessibility"
            )
            permissionState.requiresAccessibility = true
            publish(permissionState)
            if !permissionPrompted {
                permissionPrompted = true
                permissionNoticeShown = true
                promptForAccessibility()
                notify(
                    "Accessibility permission required",
                    "Enable TeamsMicFloat.app in System Settings → Privacy & Security → Accessibility (or Device Control and Data Access). The floating button will connect automatically once access is granted.",
                    .warning
                )
            }
            return
        }

        permissionPrompted = false
        if permissionNoticeShown {
            permissionNoticeShown = false
            notify(
                "Accessibility enabled",
                "Teams Mic Float can now read and control the Teams microphone.",
                .success
            )
        }

        guard let app = teamsApplication() else {
            microphoneElement = nil
            teamsAX = nil
            teamsPID = nil
            publish(
                ClientState(
                    phase: .disconnected,
                    connected: false,
                    detail: "Teams is not running",
                    lastError: "Open Microsoft Teams to connect"
                )
            )
            return
        }

        if teamsPID != app.processIdentifier || teamsAX == nil {
            teamsPID = app.processIdentifier
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetAttributeValue(
                ax,
                "AXEnhancedUserInterface" as CFString,
                kCFBooleanTrue
            )
            AXUIElementSetAttributeValue(
                ax,
                "AXManualAccessibility" as CFString,
                kCFBooleanTrue
            )
            teamsAX = ax
            microphoneElement = nil
            Log.info("Connected to Teams accessibility tree (pid \(app.processIdentifier))")
        }

        guard let appElement = teamsAX else { return }
        let windows = windowElements(for: appElement)

        // Fast path: the control we found last time usually stays valid across
        // mute changes.  Verify that its meeting window still exists.
        if let microphone = microphoneElement {
            if let rawWindow = value(microphone, kAXWindowAttribute),
               let window = axElement(rawWindow),
               isMeetingWindow(window) {
                applyState(microphone: microphone)
                return
            }
            microphoneElement = nil
        }

        let meetingWindows = windows.filter { isMeetingWindow($0) }
        for window in meetingWindows {
            if let microphone = findMicrophoneButton(in: window) {
                microphoneElement = microphone
                applyState(microphone: microphone)
                return
            }
        }

        if !meetingWindows.isEmpty {
            // A call exists but its control bar is not currently exposed.  This
            // usually means the meeting window is minimized or on another Space.
            publish(
                ClientState(
                    phase: .connected,
                    connected: true,
                    inMeeting: true,
                    muteKnown: false,
                    canToggleMute: false,
                    detail: "Meeting detected — restore the Teams meeting window"
                )
            )
        } else {
            publish(
                ClientState(
                    phase: .connected,
                    connected: true,
                    detail: "Teams running — not in a call"
                )
            )
        }
    }

    // MARK: - Actions

    private func performPrimaryAction() {
        guard running else { return }

        if !AXIsProcessTrusted() {
            openAccessibilitySettings()
            return
        }

        if let microphone = microphoneElement {
            let now = Date()
            guard now.timeIntervalSince(lastPress) > 0.45 else { return }
            let result = AXUIElementPerformAction(
                microphone,
                kAXPressAction as CFString
            )
            if result == .success {
                lastPress = now
                Log.info("Pressed Teams microphone button through Accessibility")
                queue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    self?.tick()
                }
            } else {
                Log.warn("AXPress on the Teams microphone failed: \(result.rawValue)")
                microphoneElement = nil
                notify(
                    "Could not control Teams",
                    "The Teams microphone button is no longer accessible. Restore the meeting window and try again.",
                    .warning
                )
                tick()
            }
            return
        }

        if state.inMeeting {
            notify(
                "Microphone control unavailable",
                "Restore the Teams meeting window so its controls become accessible.",
                .warning
            )
            reconnect()
            return
        }

        if teamsApplication() == nil {
            notify(
                "Teams is not running",
                "Open Microsoft Teams, then click the floating button again.",
                .warning
            )
        } else {
            notify(
                "Not in a call",
                "Join a Teams call to enable the microphone button.",
                .info
            )
        }
        reconnect()
    }

    // MARK: - State application

    private func applyState(microphone: AXUIElement) {
        let muted = microphoneMutedState(microphone)
        let known = muted != nil
        publish(
            ClientState(
                phase: .connected,
                connected: true,
                inMeeting: true,
                muted: muted ?? false,
                muteKnown: known,
                canToggleMute: true,
                detail: known
                    ? (muted == true ? "In call — muted" : "In call — unmuted")
                    : "In call — mute state unavailable"
            )
        )
    }

    private func microphoneMutedState(_ microphone: AXUIElement) -> Bool? {
        let values = [
            string(microphone, kAXTitleAttribute),
            string(microphone, kAXDescriptionAttribute),
            string(microphone, kAXHelpAttribute),
            string(microphone, kAXValueAttribute),
        ]
        for raw in values {
            let text = raw.lowercased()
            if text.contains("unmute") {
                // The action offered is "Unmute", so the mic is currently muted.
                return true
            }
            if text.contains("mute mic") || text == "mute" {
                return false
            }
        }
        return nil
    }

    private func publish(_ newState: ClientState) {
        stateLock.lock()
        let changed = newState != internalState
        if changed {
            internalState = newState
        }
        stateLock.unlock()

        guard changed else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onState?(newState)
        }
    }

    private func notify(_ title: String, _ message: String, _ level: NoticeLevel) {
        DispatchQueue.main.async { [weak self] in
            self?.onNotice?(Notice(title: title, message: message, level: level))
        }
    }

    private func promptForAccessibility() {
        guard !AXIsProcessTrusted() else { return }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    // MARK: - Accessibility helpers

    private func teamsApplication() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.microsoft.teams2"
        ).first
    }

    private func windowElements(for app: AXUIElement) -> [AXUIElement] {
        if let windows = value(app, kAXWindowsAttribute) as? [AXUIElement],
           !windows.isEmpty {
            return windows
        }
        return children(app).filter {
            string($0, kAXRoleAttribute) == "AXWindow"
        }
    }

    private func isMeetingWindow(_ window: AXUIElement) -> Bool {
        let title = string(window, kAXTitleAttribute).lowercased()
        let subrole = string(window, kAXSubroleAttribute)
        if subrole == "AXSystemDialog" {
            return true
        }
        return title.contains("meeting")
            || title.contains("call")
            || title.contains("meet now")
            || title.contains("meeting compact view")
    }

    private func findMicrophoneButton(in root: AXUIElement) -> AXUIElement? {
        var stack: [AXUIElement] = [root]
        var visited = Set<CFHashCode>()
        var inspected = 0

        while let element = stack.popLast() {
            inspected += 1
            if inspected > 5000 { break }
            let hash = CFHash(element)
            if visited.contains(hash) { continue }
            visited.insert(hash)

            if string(element, "AXDOMIdentifier") == "microphone-button" {
                return element
            }

            let role = string(element, kAXRoleAttribute)
            if role == "AXButton" {
                let title = string(element, kAXTitleAttribute)
                let description = string(element, kAXDescriptionAttribute)
                let combined = (title + " " + description).lowercased()
                if combined.contains("mute mic") || combined.contains("unmute mic") {
                    return element
                }
            }

            for child in children(element) {
                stack.append(child)
            }
        }
        return nil
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &result
        )
        return error == .success ? (result as AnyObject?) : nil
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String {
        guard let value = value(element, attribute) else { return "" }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private func axElement(_ value: AnyObject) -> AXUIElement? {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

// MARK: - Pure matching helpers for tests

enum TeamsAccessibilityMatcher {
    static func isMicrophoneElement(role: String, domID: String, title: String, description: String) -> Bool {
        if domID == "microphone-button" { return true }
        guard role == "AXButton" else { return false }
        let combined = (title + " " + description).lowercased()
        return combined.contains("mute mic") || combined.contains("unmute mic")
    }

    static func isMuted(title: String, description: String, help: String = "", value: String = "") -> Bool? {
        for raw in [title, description, help, value] {
            let text = raw.lowercased()
            if text.contains("unmute") {
                return true
            }
            if text.contains("mute mic") || text == "mute" {
                return false
            }
        }
        return nil
    }

    static func isMeetingWindow(title: String, subrole: String) -> Bool {
        if subrole == "AXSystemDialog" { return true }
        let lower = title.lowercased()
        return lower.contains("meeting") || lower.contains("call") || lower.contains("meet now")
    }
}

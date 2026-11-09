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
        // mute changes.  Verify that its element and window still exist.
        if let microphone = microphoneElement {
            if isElementValid(microphone),
               let rawWindow = value(microphone, kAXWindowAttribute),
               let window = axElement(rawWindow),
               isElementValid(window) {
                applyState(microphone: microphone)
                return
            }
            microphoneElement = nil
        }

        // Search windows for the microphone button. Prioritize likely call or
        // meeting windows, but check all windows (the call may be embedded in
        // the main window or in a dedicated 1:1 call window).
        let orderedWindows = windows.sorted { (w1, w2) -> Bool in
            let m1 = isMeetingWindow(w1)
            let m2 = isMeetingWindow(w2)
            return m1 && !m2
        }

        for window in orderedWindows {
            if let microphone = findMicrophoneButton(in: window) {
                microphoneElement = microphone
                applyState(microphone: microphone)
                return
            }
        }

        let meetingWindows = windows.filter { isMeetingWindow($0) }
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
        TeamsAccessibilityMatcher.isMuted(
            title: string(microphone, kAXTitleAttribute),
            description: string(microphone, kAXDescriptionAttribute),
            help: string(microphone, kAXHelpAttribute),
            value: string(microphone, kAXValueAttribute)
        )
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
        var result: [AXUIElement] = []
        var seen = Set<CFHashCode>()

        func add(_ elem: AXUIElement?) {
            guard let elem else { return }
            let hash = CFHash(elem)
            if !seen.contains(hash) {
                seen.insert(hash)
                result.append(elem)
            }
        }

        if let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] {
            for w in windows { add(w) }
        }
        if let raw = value(app, kAXMainWindowAttribute), let mw = axElement(raw) {
            add(mw)
        }
        if let raw = value(app, kAXFocusedWindowAttribute), let fw = axElement(raw) {
            add(fw)
        }
        for child in children(app) {
            if string(child, kAXRoleAttribute) == "AXWindow" {
                add(child)
            }
        }
        return result
    }

    private func isMeetingWindow(_ window: AXUIElement) -> Bool {
        let title = string(window, kAXTitleAttribute)
        let subrole = string(window, kAXSubroleAttribute)
        return TeamsAccessibilityMatcher.isMeetingWindow(title: title, subrole: subrole)
    }

    private func findMicrophoneButton(in root: AXUIElement) -> AXUIElement? {
        var queue: [AXUIElement] = [root]
        var head = 0
        var visited = Set<CFHashCode>()

        while head < queue.count {
            let element = queue[head]
            head += 1
            if head > 2500 { break }

            let hash = CFHash(element)
            if visited.contains(hash) { continue }
            visited.insert(hash)

            let domID = string(element, "AXDOMIdentifier")
            let identifier = string(element, kAXIdentifierAttribute)
            let role = string(element, kAXRoleAttribute)
            let title = string(element, kAXTitleAttribute)
            let description = string(element, kAXDescriptionAttribute)
            let help = string(element, kAXHelpAttribute)

            if TeamsAccessibilityMatcher.isMicrophoneElement(
                role: role,
                domID: domID,
                title: title,
                description: description,
                help: help,
                identifier: identifier
            ) {
                return element
            }

            for child in children(element) {
                queue.append(child)
            }
        }
        return nil
    }

    private func isElementValid(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &role
        )
        return err == .success && role != nil
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
    static func isMicrophoneElement(
        role: String,
        domID: String,
        title: String,
        description: String,
        help: String = "",
        identifier: String = ""
    ) -> Bool {
        if domID == "microphone-button" || domID.contains("microphone-button") || domID == "mic-button" {
            return true
        }
        if identifier == "microphone-button" || identifier.contains("microphone-button") || identifier == "mic-button" {
            return true
        }

        let validRoles: Set<String> = [
            "AXButton",
            "AXPopUpButton",
            "AXCheckBox",
            "AXRadioButton",
            "AXToggle",
        ]
        guard validRoles.contains(role) else { return false }

        let combined = (title + " " + description + " " + help).lowercased()
        if combined.contains("mute chat") || combined.contains("notifications") {
            return false
        }

        // Teams keyboard shortcut: Cmd+Shift+M / Ctrl+Shift+M
        if combined.contains("shift") && combined.contains("m") && (combined.contains("mute") || combined.contains("mic")) {
            return true
        }

        // Common mute / unmute phrases for microphone
        if combined.contains("mute mic") || combined.contains("unmute mic") { return true }
        if combined.contains("mute microphone") || combined.contains("unmute microphone") { return true }
        if combined.contains("turn off microphone") || combined.contains("turn on microphone") { return true }
        if combined.contains("microphone is muted") || combined.contains("microphone is unmuted") { return true }
        if combined.contains("mic is muted") || combined.contains("mic is unmuted") { return true }

        // Short labels if mic or microphone is explicitly involved
        if (combined.contains("mic") || combined.contains("microphone")) && (combined.contains("mute") || combined.contains("unmute")) {
            return true
        }

        // Standalone "Mute" or "Unmute" button label on a call toolbar
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let d = description.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t == "mute" || t == "unmute" || d == "mute" || d == "unmute" {
            return true
        }

        return false
    }

    static func isMuted(
        title: String,
        description: String,
        help: String = "",
        value: String = ""
    ) -> Bool? {
        for raw in [title, description, help, value] {
            let text = raw.lowercased()
            guard !text.isEmpty else { continue }

            if text.contains("unmute")
                || text.contains("turn on microphone")
                || text.contains("microphone is muted")
                || text.contains("mic is muted") {
                return true
            }
            if text.contains("mute")
                || text.contains("turn off microphone")
                || text.contains("microphone is on")
                || text.contains("microphone is unmuted")
                || text.contains("mic is on")
                || text.contains("mic is unmuted") {
                return false
            }
        }
        return nil
    }

    static func isMeetingWindow(title: String, subrole: String) -> Bool {
        if subrole == "AXSystemDialog" { return true }
        let lower = title.lowercased()
        if lower.contains("meeting")
            || lower.contains("call")
            || lower.contains("meet now")
            || lower.contains("compact view")
            || lower.contains("ringing") {
            return true
        }
        // Teams popped-out call/meeting windows have "<Subject/Contact> | Microsoft Teams"
        // and do not represent main navigation tabs (Chat |, Teams |, Calendar |, Activity |).
        if lower.contains("| microsoft teams") {
            let isMainTab = lower.starts(with: "chat |")
                || lower.starts(with: "teams |")
                || lower.starts(with: "calendar |")
                || lower.starts(with: "activity |")
                || lower.starts(with: "calls |")
            return !isMainTab
        }
        return false
    }
}

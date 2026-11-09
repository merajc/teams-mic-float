import AppKit
import ApplicationServices
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: AppOptions
    private var config: ConfigStore?
    private var controller: TeamsAccessibilityController?
    private var arduinoController: ArduinoSerialController?
    private var panelController: FloatingPanelController?
    private var toastController: ToastController?
    private var statusItem: NSStatusItem?
    private var lastVisual: VisualState?
    private var terminating = false

    init(options: AppOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.verbose = options.debug
        configureMainMenu()

        do {
            config = try ConfigStore(url: options.configURL)
        } catch {
            Log.error("Could not initialize config: \(error.localizedDescription)")
            presentFatalError(error.localizedDescription)
            return
        }
        guard let config else { return }

        let controller = TeamsAccessibilityController()
        self.controller = controller

        let panelController = FloatingPanelController(
            config: config,
            onPrimary: { [weak self] in
                self?.controller?.requestPrimaryAction()
            },
            onReconnect: { [weak self] in
                self?.controller?.reconnect()
            },
            onContextMenu: { [weak self] event in
                self?.showContextMenu(event)
            }
        )
        self.panelController = panelController

        let toastController = ToastController(anchor: { [weak self, weak panelController] in
            if panelController?.isVisible == true {
                return panelController?.panel.frame
            }
            if let window = self?.statusItem?.button?.window {
                return window.frame
            }
            return panelController?.panel.frame
        })
        self.toastController = toastController

        let arduinoController = ArduinoSerialController()
        self.arduinoController = arduinoController
        arduinoController.onToggle = { [weak self] in
            Task { @MainActor [weak self] in
                self?.controller?.requestPrimaryAction()
            }
        }
        arduinoController.onStatusChanged = { [weak self] _ in
            Task { @MainActor [weak self] in
                if let state = self?.controller?.state {
                    self?.statusItem?.menu = self?.buildMenu(state: state)
                }
            }
        }
        arduinoController.onConnected = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let state = self.controller?.state else { return }
                if state.inMeeting {
                    self.arduinoController?.send(state.muted ? "MUTED" : "UNMUTED")
                } else {
                    self.arduinoController?.send("OFF")
                }
            }
        }

        controller.onState = { [weak self] state in
            self?.apply(state)
            if state.inMeeting {
                self?.arduinoController?.send(state.muted ? "MUTED" : "UNMUTED")
            } else {
                self?.arduinoController?.send("OFF")
            }
        }
        controller.onNotice = { [weak self] notice in
            self?.toastController?.show(
                title: notice.title,
                message: notice.message,
                level: notice.level
            )
        }

        configureStatusItem()
        updatePanelVisibility(state: controller.state)
        apply(controller.state)
        controller.start()
        arduinoController.start()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )

        Log.info("Teams Mic Float \(AppOptions.version) — Accessibility backend")
        Log.info("Config: \(config.path)")
        Log.info("Teams microphone is controlled via macOS Accessibility")

        if !AXIsProcessTrusted() {
            Log.warn("Accessibility permission is not granted yet")
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller, !terminating else { return .terminateNow }
        terminating = true
        arduinoController?.stop()
        panelController?.savePosition()
        toastController?.hide()
        Task {
            await controller.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelController?.savePosition()
    }

    @objc private func systemDidWake() {
        Log.info("System woke; refreshing the Teams accessibility connection and Arduino")
        controller?.reconnect()
        arduinoController?.reconnect()
    }

    // MARK: - UI updates

    private func apply(_ state: ClientState) {
        panelController?.update(state: state)
        updatePanelVisibility(state: state)
        updateStatusItem(state: state)
        statusItem?.menu = buildMenu(state: state)
        lastVisual = VisualState.from(state)
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.toolTip = "Teams Mic Float"
        }
        statusItem = item
        if let state = controller?.state {
            updateStatusItem(state: state)
            item.menu = buildMenu(state: state)
        }
    }

    private func updateStatusItem(state: ClientState) {
        guard let button = statusItem?.button else { return }
        let visual = VisualState.from(state)
        let symbol: String
        switch visual {
        case .muted: symbol = "mic.slash.fill"
        case .unmuted: symbol = "mic.fill"
        case .permission: symbol = "accessibility"
        case .pairing: symbol = "person.badge.key.fill"
        case .connecting: symbol = "arrow.triangle.2.circlepath"
        case .syncing: symbol = "waveform"
        case .idle, .offline: symbol = "mic"
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        if let image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: "Teams microphone"
        ) {
            let configured = image.withSymbolConfiguration(configuration) ?? image
            switch visual {
            case .muted:
                configured.isTemplate = false
                button.image = configured
                button.contentTintColor = NSColor.systemRed
            case .unmuted:
                configured.isTemplate = false
                button.image = configured
                button.contentTintColor = NSColor.systemGreen
            case .permission, .connecting, .pairing:
                configured.isTemplate = false
                button.image = configured
                button.contentTintColor = NSColor.systemOrange
            case .syncing:
                configured.isTemplate = false
                button.image = configured
                button.contentTintColor = NSColor.systemYellow
            case .idle, .offline:
                // Template image with nil tint color ensures high-contrast white in Dark Mode
                // and dark charcoal in Light Mode, exactly like system icons (Clock, Battery, WiFi).
                configured.isTemplate = true
                button.image = configured
                button.contentTintColor = nil
            }
        }
        button.toolTip = "\(visual.statusTitle(state))\n\(visual.statusHint(state))"
        button.appearsDisabled = false
    }

    private func buildMenu(state: ClientState) -> NSMenu {
        let visual = VisualState.from(state)
        let menu = NSMenu()
        menu.autoenablesItems = false

        let status = NSMenuItem(
            title: visual.statusTitle(state),
            action: nil,
            keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let primaryTitle: String
        let primaryAction: Selector
        let primaryEnabled: Bool
        if visual == .permission {
            primaryTitle = "Open Accessibility Settings"
            primaryAction = #selector(openAccessibility)
            primaryEnabled = true
        } else if state.canToggle {
            primaryTitle = state.muted ? "Unmute" : "Mute"
            primaryAction = #selector(primaryFromMenu)
            primaryEnabled = true
        } else if state.inMeeting {
            primaryTitle = "Restore Teams Meeting Window"
            primaryAction = #selector(refreshFromMenu)
            primaryEnabled = true
        } else if state.connected {
            primaryTitle = "Not in a Call"
            primaryAction = #selector(primaryFromMenu)
            primaryEnabled = false
        } else {
            primaryTitle = "Retry Teams Detection"
            primaryAction = #selector(refreshFromMenu)
            primaryEnabled = true
        }
        let primary = NSMenuItem(
            title: primaryTitle,
            action: primaryAction,
            keyEquivalent: "m"
        )
        primary.target = self
        primary.isEnabled = primaryEnabled
        menu.addItem(primary)

        let refresh = NSMenuItem(
            title: "Refresh Teams Detection",
            action: #selector(refreshFromMenu),
            keyEquivalent: "r"
        )
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())

        let windowMenu = NSMenu()
        windowMenu.autoenablesItems = false

        let hiddenItem = NSMenuItem(
            title: "Hide (Menu Bar Only)",
            action: #selector(setWindowModeHidden),
            keyEquivalent: ""
        )
        hiddenItem.target = self
        hiddenItem.state = (config?.floatingWindowMode == .hidden) ? .on : .off
        windowMenu.addItem(hiddenItem)

        let inCallItem = NSMenuItem(
            title: "Show During Calls Only",
            action: #selector(setWindowModeInCall),
            keyEquivalent: ""
        )
        inCallItem.target = self
        inCallItem.state = (config?.floatingWindowMode == .inCallOnly) ? .on : .off
        windowMenu.addItem(inCallItem)

        let alwaysItem = NSMenuItem(
            title: "Show Always",
            action: #selector(setWindowModeAlways),
            keyEquivalent: ""
        )
        alwaysItem.target = self
        alwaysItem.state = (config?.floatingWindowMode == .always) ? .on : .off
        windowMenu.addItem(alwaysItem)

        let windowParent = NSMenuItem(
            title: "Floating Button",
            action: nil,
            keyEquivalent: ""
        )
        windowParent.submenu = windowMenu
        menu.addItem(windowParent)

        menu.addItem(.separator())

        let accessibility = NSMenuItem(
            title: "Accessibility Settings…",
            action: #selector(openAccessibility),
            keyEquivalent: ""
        )
        accessibility.target = self
        menu.addItem(accessibility)

        let help = NSMenuItem(
            title: "Accessibility Help…",
            action: #selector(accessibilityHelp),
            keyEquivalent: ""
        )
        help.target = self
        menu.addItem(help)

        menu.addItem(.separator())
        if let arduino = arduinoController {
            let statusText = arduino.isConnected
                ? "🟢 Arduino: Connected (\(arduino.portName ?? "USB"))"
                : "🔴 Arduino: Disconnected"
            let arduinoItem = NSMenuItem(
                title: statusText,
                action: nil,
                keyEquivalent: ""
            )
            arduinoItem.isEnabled = false
            menu.addItem(arduinoItem)

            let reconnectItem = NSMenuItem(
                title: "Reconnect Arduino",
                action: #selector(reconnectArduino),
                keyEquivalent: ""
            )
            reconnectItem.target = self
            menu.addItem(reconnectItem)

            let diagItem = NSMenuItem(
                title: "Arduino Diagnostics…",
                action: #selector(showArduinoDiagnostics),
                keyEquivalent: ""
            )
            diagItem.target = self
            menu.addItem(diagItem)
            menu.addItem(.separator())
        }

        let startAtLoginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleStartAtLogin),
            keyEquivalent: ""
        )
        startAtLoginItem.target = self
        startAtLoginItem.state = isStartAtLoginEnabled ? .on : .off
        menu.addItem(startAtLoginItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Teams Mic Float",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    private func showContextMenu(_ event: NSEvent) {
        guard let view = panelController?.statusView, let state = controller?.state else { return }
        NSMenu.popUpContextMenu(buildMenu(state: state), with: event, for: view)
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        let quit = NSMenuItem(
            title: "Quit Teams Mic Float",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu actions

    private func updatePanelVisibility(state: ClientState) {
        guard let panelController, let config else { return }
        switch config.floatingWindowMode {
        case .hidden:
            panelController.hide()
        case .inCallOnly:
            if state.inMeeting {
                panelController.show()
            } else {
                panelController.hide()
            }
        case .always:
            panelController.show()
        }
    }

    @objc private func setWindowModeHidden() {
        setFloatingWindowMode(.hidden)
    }

    @objc private func setWindowModeInCall() {
        setFloatingWindowMode(.inCallOnly)
    }

    @objc private func setWindowModeAlways() {
        setFloatingWindowMode(.always)
    }

    private func setFloatingWindowMode(_ mode: FloatingWindowMode) {
        do {
            try config?.setFloatingWindowMode(mode)
            if let state = controller?.state {
                updatePanelVisibility(state: state)
                statusItem?.menu = buildMenu(state: state)
            }
        } catch {
            Log.warn("Could not save floating window mode: \(error.localizedDescription)")
        }
    }

    @objc private func primaryFromMenu() {
        controller?.requestPrimaryAction()
    }

    @objc private func refreshFromMenu() {
        controller?.reconnect()
    }

    @objc private func openAccessibility() {
        controller?.openAccessibilitySettings()
    }

    @objc private func accessibilityHelp() {
        toastController?.show(
            title: "Enable Accessibility",
            message: "Open System Settings → Privacy & Security → Accessibility and enable Teams Mic Float. Teams must be running, with the meeting window visible for control.",
            level: .info,
            duration: 20
        )
    }

    @objc private func reconnectArduino() {
        Log.info("Manual Arduino reconnect requested from menu")
        arduinoController?.reconnect()
    }

    @objc private func showArduinoDiagnostics() {
        guard let arduino = arduinoController else { return }
        arduino.ping()

        let alert = NSAlert()
        alert.messageText = "Arduino Hardware Diagnostics"
        var lines: [String] = []
        for (key, val) in arduino.diagnostics.sorted(by: { $0.key < $1.key }) {
            lines.append("• \(key): \(val)")
        }
        lines.append("")
        lines.append("Hardware Pins:")
        lines.append("• MAX7219 DIN = Pin 8 | CS = Pin 9 | CLK = Pin 10")
        lines.append("• Tactile Button = Pin 2 to GND (INPUT_PULLUP, <15ms)")
        lines.append("")
        lines.append("A PING was sent to test roundtrip communication.")
        alert.informativeText = lines.joined(separator: "\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Reconnect Now")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            reconnectArduino()
        }
    }

    private var isStartAtLoginEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc private func toggleStartAtLogin() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                    Log.info("Unregistered from Launch at Login")
                } else {
                    try SMAppService.mainApp.register()
                    Log.info("Registered for Launch at Login")
                }
                if let state = controller?.state {
                    statusItem?.menu = buildMenu(state: state)
                }
            } catch {
                Log.warn("Failed to toggle Launch at Login: \(error.localizedDescription)")
                toastController?.show(
                    title: "Launch at Login",
                    message: "You can also manage login items in System Settings → General → Login Items.",
                    level: .info
                )
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func presentFatalError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Teams Mic Float could not start"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }
}

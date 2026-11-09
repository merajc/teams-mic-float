import AppKit

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingPanelController {
    static let size = NSSize(width: 124, height: 124)

    let panel: FloatingPanel
    let statusView: StatusView

    private let config: ConfigStore
    private let onPrimary: () -> Void
    private let onReconnect: () -> Void
    private let onContextMenu: (NSEvent) -> Void

    init(
        config: ConfigStore,
        onPrimary: @escaping () -> Void,
        onReconnect: @escaping () -> Void,
        onContextMenu: @escaping (NSEvent) -> Void
    ) {
        self.config = config
        self.onPrimary = onPrimary
        self.onReconnect = onReconnect
        self.onContextMenu = onContextMenu

        let statusView = StatusView(frame: NSRect(origin: .zero, size: Self.size))
        self.statusView = statusView

        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Teams Mic Float"
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.tabbingMode = .disallowed
        panel.contentView = statusView
        self.panel = panel

        statusView.onPrimary = onPrimary
        statusView.onDragEnd = { [weak self] origin in
            self?.store(origin: origin)
        }
        statusView.onShowContextMenu = onContextMenu
        placeWindow()
    }

    var isVisible: Bool {
        panel.isVisible
    }

    func show() {
        if !panel.isVisible {
            panel.orderFrontRegardless()
            Log.info("Floating panel shown at \(NSStringFromPoint(panel.frame.origin))")
        }
    }

    func hide() {
        if panel.isVisible {
            panel.orderOut(nil)
            Log.info("Floating panel hidden")
        }
    }

    func update(state: ClientState) {
        statusView.update(state: state)
    }

    func savePosition() {
        store(origin: panel.frame.origin)
    }

    private func placeWindow() {
        let origin = preferredOrigin()
        panel.setFrameOrigin(origin)
    }

    private func preferredOrigin() -> NSPoint {
        if let stored = config.windowPosition() {
            let point = NSPoint(
                x: CGFloat(stored.x) + Self.size.width / 2,
                y: CGFloat(stored.y) + Self.size.height / 2
            )
            if let screen = NSScreen.screens.first(where: {
                NSMouseInRect(point, $0.visibleFrame, false)
            }) {
                return clamped(
                    NSPoint(x: CGFloat(stored.x), y: CGFloat(stored.y)),
                    to: screen.visibleFrame
                )
            }
        }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return NSPoint(x: 100, y: 100)
        }
        let visible = screen.visibleFrame
        return NSPoint(
            x: visible.maxX - Self.size.width - 24,
            y: visible.minY + 68
        )
    }

    private func clamped(_ origin: NSPoint, to visible: NSRect) -> NSPoint {
        NSPoint(
            x: min(
                max(origin.x, visible.minX + 8),
                visible.maxX - Self.size.width - 8
            ),
            y: min(
                max(origin.y, visible.minY + 8),
                visible.maxY - Self.size.height - 8
            )
        )
    }

    private func store(origin: NSPoint) {
        do {
            try config.setWindowPosition(
                x: Int(origin.x.rounded()),
                y: Int(origin.y.rounded())
            )
        } catch {
            Log.warn("Could not save window position: \(error.localizedDescription)")
        }
    }
}

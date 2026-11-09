import AppKit

private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ToastView: NSView {
    var onDismiss: (() -> Void)?

    private let title: String
    private let body: String
    private let accent: NSColor

    override var isFlipped: Bool { true }

    init(title: String, body: String, level: NoticeLevel, width: CGFloat, height: CGFloat) {
        self.title = title
        self.body = body
        switch level {
        case .success: accent = NSColor(hex: "#35E08C")
        case .warning: accent = NSColor(hex: "#FBBF24")
        case .error: accent = NSColor(hex: "#FF4D5E")
        case .info: accent = NSColor(hex: "#7C8DA5")
        }
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(title). \(body)")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func measureHeight(title: String, body: String, width: CGFloat) -> CGFloat {
        let textWidth = width - 32
        let titleHeight = (title as NSString).boundingRect(
            with: NSSize(width: textWidth, height: 100),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .bold)]
        ).height
        let bodyHeight = (body as NSString).boundingRect(
            with: NSSize(width: textWidth, height: 400),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 9.5, weight: .regular)]
        ).height
        return max(76, ceil(12 + titleHeight + 4 + bodyHeight + 12))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.shouldAntialias = true
        let cardRect = bounds.insetBy(dx: 1, dy: 1)
        let card = NSBezierPath(roundedRect: cardRect, xRadius: 14, yRadius: 14)

        NSColor(hex: "#111827").setFill()
        card.fill()
        NSColor(hex: "#263244").setStroke()
        card.lineWidth = 1
        card.stroke()

        NSGraphicsContext.saveGraphicsState()
        card.addClip()
        accent.setFill()
        NSRect(x: 0, y: 0, width: 4, height: bounds.height).fill()
        NSGraphicsContext.restoreGraphicsState()

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .left

        (title as NSString).draw(
            in: NSRect(x: 16, y: 11, width: bounds.width - 42, height: 18),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .bold),
                .foregroundColor: NSColor(hex: "#F8FAFC"),
                .paragraphStyle: paragraph,
            ]
        )

        (body as NSString).draw(
            in: NSRect(x: 16, y: 32, width: bounds.width - 32, height: bounds.height - 40),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .regular),
                .foregroundColor: NSColor(hex: "#CBD5E1"),
                .paragraphStyle: paragraph,
            ]
        )

        ("×" as NSString).draw(
            in: NSRect(x: bounds.width - 25, y: 6, width: 18, height: 18),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor(hex: "#94A3B8"),
                .paragraphStyle: paragraph,
            ]
        )
    }

    override func mouseDown(with event: NSEvent) {
        onDismiss?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class ToastController {
    private let anchor: () -> NSRect?
    private let width: CGFloat = 310
    private var panel: ToastPanel?
    private var dismissTask: Task<Void, Never>?

    init(anchor: @escaping () -> NSRect?) {
        self.anchor = anchor
    }

    func show(
        title: String,
        message: String,
        level: NoticeLevel = .info,
        duration: TimeInterval = 11
    ) {
        dismissTask?.cancel()
        let height = ToastView.measureHeight(title: title, body: message, width: width)
        let view = ToastView(
            title: title,
            body: message,
            level: level,
            width: width,
            height: height
        )
        view.onDismiss = { [weak self] in
            self?.hide()
        }

        let panel = self.panel ?? makePanel()
        panel.setContentSize(NSSize(width: width, height: height))
        panel.contentView = view
        self.panel = panel
        position(panel: panel, height: height)
        panel.orderFrontRegardless()

        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> ToastPanel {
        let panel = ToastPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 90),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
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
        panel.animationBehavior = .none
        panel.tabbingMode = .disallowed
        return panel
    }

    private func position(panel: NSPanel, height: CGFloat) {
        guard let anchorRect = anchor() else { return }
        let screen =
            NSScreen.screens.first(where: {
                NSMouseInRect(NSPoint(x: anchorRect.midX, y: anchorRect.midY), $0.visibleFrame, false)
            }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchorRect
        var x = anchorRect.minX - width - 12
        if x < visible.minX + 8 {
            x = anchorRect.maxX + 12
        }
        x = min(max(x, visible.minX + 8), visible.maxX - width - 8)
        let y = min(
            max(anchorRect.minY, visible.minY + 8),
            visible.maxY - height - 8
        )
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

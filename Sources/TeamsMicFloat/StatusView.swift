import AppKit
import QuartzCore

final class StatusView: NSView {
    var onPrimary: (() -> Void)?
    var onDragEnd: ((NSPoint) -> Void)?
    var onShowContextMenu: ((NSEvent) -> Void)?

    private(set) var state = ClientState()
    private var visual: VisualState = .offline
    private var isHovered = false
    private var isDragging = false
    private var dragStartMouse = NSPoint.zero
    private var dragStartOrigin = NSPoint.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Teams microphone")
        setAccessibilityHelp("Click to toggle the Teams microphone")
        updateAccessibility()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        onPrimary?()
        return true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func updateTrackingAreas() {
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    func update(state: ClientState) {
        let newVisual = VisualState.from(state)
        let changed = newVisual != self.visual
        self.state = state
        self.visual = newVisual
        toolTip = "\(newVisual.statusTitle(state))\n\(newVisual.statusHint(state))"
        updateAccessibility()
        needsDisplay = true
        if changed {
            pulse()
        }
    }

    private func updateAccessibility() {
        let title = visual.statusTitle(state)
        setAccessibilityValue(title)
        setAccessibilityHelp(visual.statusHint(state))
    }

    private func pulse() {
        guard let layer else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.55
        animation.toValue = 1.0
        animation.duration = 0.18
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "statePulse")
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSGraphicsContext.current?.shouldAntialias = true

        let palette = visual.palette
        let ring = NSColor(hex: palette.ring)
        let glow = NSColor(hex: palette.glow)
        let icon = NSColor(hex: palette.icon)
        let dot = NSColor(hex: palette.dot)
        let card = NSColor(hex: "#0B111A")
        let cardEdge = NSColor(hex: "#1E293B")

        let cardRect = bounds.insetBy(dx: 5, dy: 5)
        let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: 18, yRadius: 18)

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        card.setFill()
        cardPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        cardEdge.setStroke()
        cardPath.lineWidth = 1
        cardPath.stroke()

        let center = NSPoint(x: bounds.midX, y: 72)
        let radius: CGFloat = 38

        let haloRect = NSRect(
            x: center.x - radius - 4,
            y: center.y - radius - 4,
            width: (radius + 4) * 2,
            height: (radius + 4) * 2
        )
        let halo = NSBezierPath(ovalIn: haloRect)
        glow.withAlphaComponent(0.85).setStroke()
        halo.lineWidth = isHovered ? 1.5 : 1
        halo.stroke()

        let discRect = NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        let disc = NSBezierPath(ovalIn: discRect)

        if let gradient = NSGradient(
            starting: NSColor(hex: palette.fillTop),
            ending: NSColor(hex: palette.fillBottom)
        ) {
            gradient.draw(in: disc, angle: -90)
        } else {
            NSColor(hex: palette.fillTop).setFill()
            disc.fill()
        }

        ring.setStroke()
        disc.lineWidth = isHovered ? 3.8 : 3
        disc.stroke()

        // Status dot on the upper-right edge of the disc.
        let dotRect = NSRect(
            x: center.x + radius - 13,
            y: center.y + radius - 23,
            width: 8,
            height: 8
        )
        let dotPath = NSBezierPath(ovalIn: dotRect)
        dot.setFill()
        dotPath.fill()
        NSColor(hex: "#0B111A").setStroke()
        dotPath.lineWidth = 2
        dotPath.stroke()

        drawMicrophone(center: center, color: icon)
        drawLabels(center: center, palette: palette)
    }

    private func drawMicrophone(center: NSPoint, color: NSColor) {
        color.setFill()
        let body = NSBezierPath(
            roundedRect: NSRect(
                x: center.x - 5,
                y: center.y + 5,
                width: 10,
                height: 18
            ),
            xRadius: 5,
            yRadius: 5
        )
        body.fill()

        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: NSPoint(x: center.x, y: center.y + 12),
            radius: 10,
            startAngle: 200,
            endAngle: 340,
            clockwise: false
        )
        arc.lineWidth = 2
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()

        let stem = NSBezierPath()
        stem.move(to: NSPoint(x: center.x, y: center.y + 2))
        stem.line(to: NSPoint(x: center.x, y: center.y - 3))
        stem.lineWidth = 2
        stem.lineCapStyle = .round
        stem.stroke()

        let base = NSBezierPath()
        base.move(to: NSPoint(x: center.x - 5, y: center.y - 3))
        base.line(to: NSPoint(x: center.x + 5, y: center.y - 3))
        base.lineWidth = 2
        base.lineCapStyle = .round
        base.stroke()
    }

    private func drawLabels(center: NSPoint, palette: Palette) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
            .kern: 0.2,
        ]
        let labelRect = NSRect(
            x: 14,
            y: center.y - 25,
            width: bounds.width - 28,
            height: 13
        )
        (visual.label as NSString).draw(in: labelRect, withAttributes: labelAttributes)

        let captionAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 6.5, weight: .semibold),
            .foregroundColor: NSColor(hex: "#94A3B8"),
            .paragraphStyle: paragraph,
            .kern: 0.8,
        ]
        let captionRect = NSRect(
            x: 10,
            y: 12,
            width: bounds.width - 20,
            height: 10
        )
        (visual.caption as NSString).draw(in: captionRect, withAttributes: captionAttributes)
        _ = palette
    }

    // MARK: - Mouse

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin ?? .zero
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - dragStartMouse.x
        let dy = current.y - dragStartMouse.y
        if hypot(dx, dy) > 3 {
            isDragging = true
        }
        window.setFrameOrigin(
            NSPoint(
                x: dragStartOrigin.x + dx,
                y: dragStartOrigin.y + dy
            )
        )
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            if let origin = window?.frame.origin {
                onDragEnd?(origin)
            }
        } else {
            onPrimary?()
        }
        isDragging = false
    }

    override func rightMouseDown(with event: NSEvent) {
        onShowContextMenu?(event)
    }

    override func otherMouseDown(with event: NSEvent) {
        onShowContextMenu?(event)
    }
}

extension NSColor {
    convenience init(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard value.count == 6, let number = UInt64(value, radix: 16) else {
            self.init(white: 0, alpha: 1)
            return
        }
        let red = CGFloat((number >> 16) & 0xFF) / 255
        let green = CGFloat((number >> 8) & 0xFF) / 255
        let blue = CGFloat(number & 0xFF) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

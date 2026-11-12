import AppKit

/// On-screen windows front to back, with frames in global CG coordinates.
struct WindowTarget {
    let id: CGWindowID
    let frame: CGRect
    let app: String
}

enum WindowTargets {
    static func onScreen() -> [WindowTarget] {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != me,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let rect = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
            return WindowTarget(id: id, frame: rect, app: info[kCGWindowOwnerName as String] as? String ?? "")
        }
    }
}

/// Full-screen overlay on one display for clicking a window or dragging an area.
final class PickerWindow: NSWindow {
    init(screen: NSScreen, mode: PickerView.Mode, done: @escaping (PickerView.Result?) -> Void) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        hasShadow = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        setFrame(screen.frame, display: false)
        contentView = PickerView(frame: NSRect(origin: .zero, size: screen.frame.size), screen: screen, mode: mode, done: done)
    }
    override var canBecomeKey: Bool { true }
}

final class PickerView: NSView {
    enum Mode { case window([WindowTarget]), area }
    enum Result { case window(CGWindowID), area(CGDirectDisplayID, CGRect) }

    private let screen: NSScreen
    private let mode: Mode
    private let done: (Result?) -> Void
    private var hovered: WindowTarget?
    private var dragStart: NSPoint?
    private var dragRect: NSRect?
    private var tracking: NSTrackingArea?

    init(frame: NSRect, screen: NSScreen, mode: Mode, done: @escaping (Result?) -> Void) {
        self.screen = screen
        self.mode = mode
        self.done = done
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
        updateHover()
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func cursorUpdate(with event: NSEvent) {
        if case .area = mode { NSCursor.crosshair.set() } else { NSCursor.pointingHand.set() }
    }

    // View-local (bottom-left of this screen) <-> global CG.
    private func toCG(_ r: NSRect) -> CGRect { Coords.toCG(r.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)) }
    private func toLocal(_ r: CGRect) -> NSRect { Coords.toAppKit(r).offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }

    private func updateHover() {
        guard case .window(let targets) = mode else { return }
        let m = NSEvent.mouseLocation
        let p = CGPoint(x: m.x, y: Coords.primaryHeight - m.y)
        let h = targets.first { $0.frame.contains(p) }
        if h?.id != hovered?.id { hovered = h; needsDisplay = true }
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover()
        // Hover belongs to whichever screen the pointer is on; the others clear theirs.
        for case let w as PickerWindow in NSApp.windows where w !== window { (w.contentView as? PickerView)?.updateHoverFromOutside() }
    }

    func updateHoverFromOutside() { updateHover() }

    override func mouseDown(with event: NSEvent) {
        switch mode {
        case .window:
            if let h = hovered { done(.window(h.id)) }
        case .area:
            dragStart = convert(event.locationInWindow, from: nil)
            dragRect = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard case .area = mode, let s = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        let r = NSRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y)).intersection(bounds)
        dragRect = NSRect(x: r.minX.rounded(), y: r.minY.rounded(), width: r.width.rounded(), height: r.height.rounded())
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard case .area = mode else { return }
        defer { dragStart = nil }
        guard let r = dragRect, r.width >= 40, r.height >= 40,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            dragRect = nil
            needsDisplay = true
            return
        }
        done(.area(id, toCG(r)))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { done(nil) }   // Esc
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(0.35)
        switch mode {
        case .window:
            dim.setFill()
            bounds.fill()
            if let h = hovered {
                let r = toLocal(h.frame)
                NSColor.clear.setFill()
                r.fill(using: .copy)
                NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
                r.fill()
                let border = NSBezierPath(rect: r.insetBy(dx: 1.5, dy: 1.5))
                border.lineWidth = 3
                NSColor.controlAccentColor.setStroke()
                border.stroke()
                pill(h.app.isEmpty ? "Click to record this window" : "Click to record \(h.app)", centredIn: r)
            }
            pill("Click a window to record it. Esc cancels.", atTopOf: bounds)
        case .area:
            dim.setFill()
            bounds.fill()
            if let r = dragRect {
                NSColor.clear.setFill()
                r.fill(using: .copy)
                let border = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
                border.lineWidth = 1
                NSColor.white.setStroke()
                border.stroke()
                let cg = toCG(r)
                pill("\(Int(cg.width)) × \(Int(cg.height))", centredIn: r)
            } else {
                pill("Drag to choose the area to record. Esc cancels.", atTopOf: bounds)
            }
        }
    }

    private func pill(_ text: String, centredIn r: NSRect) {
        drawPill(text, at: { size in NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2) })
    }

    private func pill(_ text: String, atTopOf r: NSRect) {
        drawPill(text, at: { size in NSPoint(x: r.midX - size.width / 2, y: r.maxY - 120) })
    }

    private func drawPill(_ text: String, at origin: (NSSize) -> NSPoint) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = NSSize(width: s.size().width + 28, height: s.size().height + 14)
        let o = origin(size)
        let rect = NSRect(origin: o, size: size)
        NSColor(white: 0.1, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: rect, xRadius: size.height / 2, yRadius: size.height / 2).fill()
        s.draw(at: NSPoint(x: rect.minX + 14, y: rect.minY + 7))
    }
}

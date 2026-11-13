import AppKit
import QuartzCore

/// Logs cursor position, clicks and cursor shapes while recording.
/// Times are host-clock seconds; the session converts them to recording time at the end.
final class InputTracker {
    private(set) var samples: [CursorSample] = []
    private(set) var clicks: [ClickEvent] = []
    private(set) var cursors: [CursorImage] = []
    private(set) var keys: [KeyEvent] = []
    private let recordKeys: Bool

    private let area: CGRect          // captured area in global CG coordinates (top-left origin)
    private let folder: URL
    private var timer: Timer?
    private var monitors: [Any] = []
    private var cursorHashes: [Int: Int] = [:]
    private var lastCursorIndex: Int?
    private var lastCursorCheck = 0.0
    private let lock = NSLock()

    init(area: CGRect, folder: URL, recordKeys: Bool = false) {
        self.area = area
        self.folder = folder
        self.recordKeys = recordKeys
    }

    func start() {
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.click(e) }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.click(e); return e }) {
            monitors.append(l)
        }
        // Shortcuts only. Global key events need Accessibility permission; without it this sees nothing.
        if recordKeys {
            if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in self?.key(e) }) {
                monitors.append(g)
            }
            if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in self?.key(e); return e }) {
                monitors.append(l)
            }
        }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func normalised(_ p: CGPoint) -> (Double, Double) {
        (Double((p.x - area.minX) / area.width), Double((p.y - area.minY) / area.height))
    }

    private func currentLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func poll() {
        let now = CACurrentMediaTime()
        let (x, y) = normalised(currentLocation())
        var cursorChange: Int?
        if now - lastCursorCheck > 0.05 {
            lastCursorCheck = now
            if let idx = captureCursor(), idx != lastCursorIndex {
                lastCursorIndex = idx
                cursorChange = idx
            }
        }
        lock.lock()
        if let last = samples.last, last.x == x, last.y == y, cursorChange == nil, now - last.t < 0.25 {
            lock.unlock()
            return
        }
        samples.append(CursorSample(t: now, x: x, y: y, cursor: cursorChange))
        lock.unlock()
    }

    private func key(_ e: NSEvent) {
        guard !e.isARepeat, let labels = Self.shortcutLabels(e) else { return }
        lock.lock()
        keys.append(KeyEvent(t: CACurrentMediaTime(), keys: labels))
        lock.unlock()
    }

    /// Labels for a shortcut, or nil for plain typing (which is never recorded).
    static func shortcutLabels(_ e: NSEvent) -> [String]? {
        let m = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let named: [UInt16: String] = [53: "esc", 36: "↩", 76: "↩", 48: "⇥", 123: "←", 124: "→", 125: "↓", 126: "↑",
                                       51: "⌫", 117: "⌦", 49: "Space"]
        let hasCommandKey = m.contains(.command) || m.contains(.control) || m.contains(.option)
        let isNamedAlone = [53, 36, 76, 48, 123, 124, 125, 126].contains(Int(e.keyCode))
        guard hasCommandKey || isNamedAlone else { return nil }
        var out: [String] = []
        if m.contains(.control) { out.append("⌃") }
        if m.contains(.option) { out.append("⌥") }
        if m.contains(.shift) { out.append("⇧") }
        if m.contains(.command) { out.append("⌘") }
        if let n = named[e.keyCode] {
            out.append(n)
        } else if let fn = Self.functionKey(e.keyCode) {
            out.append(fn)
        } else if let c = e.charactersIgnoringModifiers?.uppercased(), !c.isEmpty,
                  c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            out.append(c)
        } else {
            return nil
        }
        return out
    }

    private static func functionKey(_ code: UInt16) -> String? {
        let map: [UInt16: Int] = [122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10, 103: 11, 111: 12]
        return map[code].map { "F\($0)" }
    }

    private func click(_ e: NSEvent) {
        let (x, y) = normalised(currentLocation())
        let button: ClickEvent.Button = e.type == .leftMouseDown ? .left : (e.type == .rightMouseDown ? .right : .other)
        lock.lock()
        clicks.append(ClickEvent(t: CACurrentMediaTime(), x: x, y: y, button: button))
        lock.unlock()
    }

    /// Saves the current system cursor the first time it is seen and returns its index.
    private func captureCursor() -> Int? {
        guard let cursor = NSCursor.currentSystem else { return lastCursorIndex }
        let image = cursor.image
        guard let tiff = image.tiffRepresentation else { return lastCursorIndex }
        let key = tiff.hashValue ^ Int(cursor.hotSpot.x * 1000) ^ Int(cursor.hotSpot.y * 7)
        if let existing = cursorHashes[key] { return existing }
        guard let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return lastCursorIndex }
        let index = cursors.count
        let file = "cursor-\(index).png"
        try? png.write(to: folder.appendingPathComponent(file))
        cursors.append(CursorImage(file: file, hotspotX: cursor.hotSpot.x, hotspotY: cursor.hotSpot.y,
                                   width: image.size.width, height: image.size.height))
        cursorHashes[key] = index
        return index
    }

    /// Events rebased so t = 0 is the first screen frame.
    func events(relativeTo start: Double, duration: Double, pause: PauseClock) -> RecordingEvents {
        lock.lock(); defer { lock.unlock() }
        // Drop what happened while paused, then close the gaps. Cursor shape changes seen
        // during a pause are carried onto the next kept sample.
        var s: [CursorSample] = []
        var pending: Int?
        for x in samples {
            if pause.isInPause(x.t) { if let c = x.cursor { pending = c }; continue }
            s.append(CursorSample(t: pause.toRecording(x.t) - start, x: x.x, y: x.y, cursor: x.cursor ?? pending))
            pending = nil
        }
        // Keep the cursor shape in effect at t = 0 by carrying it on the first kept sample.
        var kept: [CursorSample] = []
        var carried: Int?
        for var sample in s {
            if sample.t < 0 { if let c = sample.cursor { carried = c }; continue }
            if sample.t > duration + 0.5 { break }
            if kept.isEmpty, sample.cursor == nil { sample.cursor = carried }
            kept.append(sample)
        }
        let c = clicks.filter { !pause.isInPause($0.t) }
            .map { ClickEvent(t: pause.toRecording($0.t) - start, x: $0.x, y: $0.y, button: $0.button) }
            .filter { $0.t >= 0 && $0.t <= duration }
        let k = keys.filter { !pause.isInPause($0.t) }
            .map { KeyEvent(t: pause.toRecording($0.t) - start, keys: $0.keys) }
            .filter { $0.t >= 0 && $0.t <= duration }
        return RecordingEvents(samples: kept, clicks: c, cursors: cursors, keys: k)
    }
}

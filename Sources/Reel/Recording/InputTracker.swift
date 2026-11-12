import AppKit
import QuartzCore

/// Logs cursor position, clicks and cursor shapes while recording.
/// Times are host-clock seconds; the session converts them to recording time at the end.
final class InputTracker {
    private(set) var samples: [CursorSample] = []
    private(set) var clicks: [ClickEvent] = []
    private(set) var cursors: [CursorImage] = []

    private let area: CGRect          // captured area in global CG coordinates (top-left origin)
    private let folder: URL
    private var timer: Timer?
    private var monitors: [Any] = []
    private var cursorHashes: [Int: Int] = [:]
    private var lastCursorIndex: Int?
    private var lastCursorCheck = 0.0
    private let lock = NSLock()

    init(area: CGRect, folder: URL) {
        self.area = area
        self.folder = folder
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
        return RecordingEvents(samples: kept, clicks: c, cursors: cursors)
    }
}

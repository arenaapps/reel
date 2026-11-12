import AppKit
import SwiftUI
import ScreenCaptureKit

/// Owns every window: the floating bar, the library, editors and the recording overlays.
@MainActor
final class WindowManager {
    static var shared: WindowManager!

    let model: AppModel
    private(set) var bar: BarPanel!
    private var library: NSWindow?
    private var editors: [URL: NSWindow] = [:]
    private var countdown: NSWindow?
    private var outline: NSWindow?
    private var pickers: [PickerWindow] = []
    private var pickContinuation: CheckedContinuation<PickerView.Result?, Never>?

    init(model: AppModel) {
        self.model = model
        bar = BarPanel(rootView: BarView(model: model))
    }

    // MARK: bar

    func showBar() {
        bar.placeAtTopIfNeeded()
        bar.orderFrontRegardless()
        bar.makeKey()
    }

    func hideBar() { bar.orderOut(nil) }

    /// The display the bar sits on, so Display records the screen you are looking at.
    func displayUnderBar(_ displays: [SCDisplay]) -> SCDisplay? {
        guard let screen = bar.screen ?? NSScreen.main,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
        return displays.first { $0.displayID == id }
    }

    // MARK: library and editors

    func showLibrary() {
        if library == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Recordings"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: LibraryView(model: model))
            w.setContentSize(NSSize(width: 880, height: 600))
            w.center()
            library = w
        }
        model.refreshProjects()
        NSApp.activate(ignoringOtherApps: true)
        library?.makeKeyAndOrderFront(nil)
    }

    func openEditor(_ url: URL) {
        if let w = editors[url] {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        guard let project = try? ReelProject.load(url) else {
            model.error = "That recording could not be opened."
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = project.document.name
        w.isReleasedWhenClosed = false
        // No system chrome: the SwiftUI top bar sits in a transparent unified title bar,
        // which keeps the window buttons centred in it.
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.toolbarStyle = .unified
        w.backgroundColor = NSColor(red: 0.075, green: 0.075, blue: 0.085, alpha: 1)
        w.appearance = NSAppearance(named: .darkAqua)
        w.minSize = NSSize(width: 1100, height: 700)
        let host = NSHostingController(rootView: EditorView(project: project))
        host.sceneBridgingOptions = [.toolbars, .title]
        w.contentViewController = host
        w.setContentSize(NSSize(width: 1440, height: 900))
        w.center()
        editors[url] = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.editors[url] = nil }
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    // MARK: picking a window or an area

    func pickWindow(_ windows: [SCWindow]) async -> SCWindow? {
        let ids = Set(windows.map(\.windowID))
        let targets = WindowTargets.onScreen().filter { ids.contains($0.id) }
        guard case .window(let id)? = await pick(.window(targets)) else { return nil }
        return windows.first { $0.windowID == id }
    }

    /// Returns the display and the dragged rectangle in global CG coordinates.
    func pickArea() async -> (CGDirectDisplayID, CGRect)? {
        guard case .area(let display, let rect)? = await pick(.area) else { return nil }
        return (display, rect)
    }

    private func pick(_ mode: PickerView.Mode) async -> PickerView.Result? {
        hideBar()
        NSApp.activate(ignoringOtherApps: true)
        let result = await withCheckedContinuation { (c: CheckedContinuation<PickerView.Result?, Never>) in
            pickContinuation = c
            pickers = NSScreen.screens.map { screen in
                let w = PickerWindow(screen: screen, mode: mode) { [weak self] result in self?.finishPick(result) }
                w.orderFrontRegardless()
                return w
            }
            let mouse = NSEvent.mouseLocation
            (pickers.first { $0.frame.contains(mouse) } ?? pickers.first)?.makeKey()
        }
        showBar()
        return result
    }

    private func finishPick(_ result: PickerView.Result?) {
        pickers.forEach { $0.orderOut(nil) }
        pickers.removeAll()
        pickContinuation?.resume(returning: result)
        pickContinuation = nil
    }

    // MARK: overlays during a recording

    /// Big 3, 2, 1 in the middle of what is about to be recorded (or of the bar's screen for a phone).
    func showCountdown(over cgRect: CGRect?) {
        hideCountdown()
        let size = NSSize(width: 168, height: 168)
        let target = cgRect.map(Coords.toAppKit) ?? (bar.screen ?? NSScreen.main)?.frame ?? .zero
        let w = OverlayWindow(contentRect: NSRect(x: target.midX - size.width / 2, y: target.midY - size.height / 2,
                                                  width: size.width, height: size.height))
        w.contentView = NSHostingView(rootView: CountdownView(model: model))
        w.orderFrontRegardless()
        countdown = w
    }

    func hideCountdown() {
        countdown?.orderOut(nil)
        countdown = nil
    }

    /// A dashed line just outside the recorded area, so you can see what is in frame.
    func showAreaOutline(_ cgRect: CGRect) {
        hideAreaOutline()
        let r = Coords.toAppKit(cgRect).insetBy(dx: -4, dy: -4)
        let w = OverlayWindow(contentRect: r)
        w.contentView = OutlineView(frame: NSRect(origin: .zero, size: r.size))
        w.orderFrontRegardless()
        outline = w
    }

    func hideAreaOutline() {
        outline?.orderOut(nil)
        outline = nil
    }
}

/// Converts between CG global coordinates (top-left of the main display) and AppKit's (bottom-left).
enum Coords {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
    static func toAppKit(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
    static func toCG(_ r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}

/// A click-through, always-on-top window for the countdown and the area outline.
final class OverlayWindow: NSWindow {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
    }
}

final class OutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
        path.lineWidth = 2
        path.setLineDash([7, 5], count: 2, phase: 0)
        NSColor.systemRed.withAlphaComponent(0.85).setStroke()
        path.stroke()
    }
}

struct CountdownView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 36, style: .continuous).fill(Color(white: 0.1).opacity(0.88))
            RoundedRectangle(cornerRadius: 36, style: .continuous).strokeBorder(.white.opacity(0.12))
            if case .countdown(let n) = model.phase {
                Text("\(n)")
                    .font(.system(size: 96, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: n)
            }
        }
        .frame(width: 168, height: 168)
    }
}

/// The floating bar. A non-activating panel so it never steals focus from the app being recorded.
final class BarPanel: NSPanel {
    private var placed = false
    private var lastTopCentre: NSPoint?

    init<V: View>(rootView: V) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 900, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false               // the SwiftUI view draws its own
        level = .floating
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        let host = NSHostingController(rootView: rootView)
        host.sizingOptions = [.preferredContentSize]
        contentViewController = host
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepTopCentre() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rememberTopCentre() }
        }
    }

    override var canBecomeKey: Bool { true }

    func placeAtTopIfNeeded() {
        guard !placed, let screen = NSScreen.main else { return }
        placed = true
        if let view = contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            setContentSize(view.fittingSize)
        }
        let v = screen.visibleFrame
        setFrameOrigin(NSPoint(x: (v.midX - frame.width / 2).rounded(), y: v.maxY - frame.height + 6))
        rememberTopCentre()
        Log.app.info("Bar placed on \(screen.localizedName, privacy: .public) at \(NSStringFromRect(self.frame), privacy: .public), visible \(NSStringFromRect(v), privacy: .public)")
    }

    private func rememberTopCentre() { lastTopCentre = NSPoint(x: frame.midX, y: frame.maxY) }

    /// When the bar grows or shrinks (ready vs recording), keep it anchored at the top centre.
    private func keepTopCentre() {
        guard let p = lastTopCentre else { return }
        setFrameOrigin(NSPoint(x: (p.x - frame.width / 2).rounded(), y: p.y - frame.height))
        Log.app.info("Bar resized to \(NSStringFromRect(self.frame), privacy: .public)")
    }
}

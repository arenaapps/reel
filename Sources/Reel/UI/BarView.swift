import SwiftUI
import AVFoundation

/// The floating recording bar (Figma: Reel > Recording bar, frames 1 to 3).
struct BarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            Group {
                switch model.phase {
                case .idle, .picking: ready
                case .countdown(let n): countdown(n)
                case .recording, .paused, .finishing: recording
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.11).opacity(0.94)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.1)))
            .shadow(color: .black.opacity(0.45), radius: 16, y: 12)

            if let error = model.error { errorPill(error) }
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 36)          // room for the shadow
        .fixedSize()
        .focusEffectDisabled()
        .environment(\.colorScheme, .dark)
        .task { await model.loadSources() }
    }

    // MARK: frame 1, ready

    private var ready: some View {
        HStack(spacing: 6) {
            IconButton(symbol: "xmark.circle.fill", size: 20, opacity: 1, help: "Hide the bar") {
                WindowManager.shared.hideBar()
            }
            BarDivider()
            ForEach(CaptureMode.allCases) { mode in
                ModeButton(mode: mode, selected: model.mode == mode) { anchor in
                    if mode == .device {
                        model.mode = .device
                        showDeviceMenu(at: anchor)
                    } else {
                        model.mode = mode
                    }
                }
            }
            BarDivider()
            Chip(symbol: model.selectedCamera == nil ? "video.slash" : "video",
                 label: model.selectedCamera.map { Self.short($0.localizedName) } ?? "No camera",
                 on: model.selectedCamera != nil, chevron: true) { showCameraMenu(at: $0) }
            Chip(symbol: model.selectedMic == nil ? "mic.slash" : "mic",
                 label: model.selectedMic.map { Self.short($0.localizedName) } ?? "No microphone",
                 on: model.selectedMic != nil, chevron: true) { showMicMenu(at: $0) }
            Chip(symbol: model.systemAudio ? "speaker.wave.2" : "speaker.slash",
                 label: "System audio", on: model.systemAudio, chevron: false) { _ in model.systemAudio.toggle() }
            BarDivider()
            IconButton(symbol: "folder", help: "Recordings") { WindowManager.shared.showLibrary() }
            AnchoredButton { anchor in showSettingsMenu(at: anchor) } label: {
                Image(systemName: "gearshape").font(.system(size: 17)).foregroundStyle(.white.opacity(0.85))
                    .frame(width: 36, height: 36).contentShape(Rectangle())
            }
            .help("Settings")
            Button { Task { await model.record() } } label: {
                HStack(spacing: 8) {
                    Circle().fill(.white).frame(width: 10, height: 10)
                    Text("Record").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.leading, 14).padding(.trailing, 16).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(red: 0.89, green: 0.24, blue: 0.2)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.phase == .picking)
            .help("Record (⌘⇧2)")
        }
    }

    // MARK: countdown

    private func countdown(_ n: Int) -> some View {
        HStack(spacing: 10) {
            IconButton(symbol: "xmark.circle.fill", size: 20, opacity: 1, help: "Cancel") { model.cancelCountdown() }
            Text("Starting in \(n)")
                .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.white)
                .padding(.trailing, 10)
        }
        .frame(height: 38)
    }

    // MARK: frame 3, recording

    private var recording: some View {
        HStack(spacing: 6) {
            Button { Task { await model.stop() } } label: {
                Image(systemName: "stop.fill").font(.system(size: 15)).foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(red: 0.89, green: 0.24, blue: 0.2)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Stop and edit (⌘⇧2)")
            .disabled(model.phase == .finishing)

            SwiftUI.TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                Text(model.phase == .finishing ? "Saving…" : Self.clock(model.elapsed))
            }
            .font(.system(size: 15, weight: .semibold)).monospacedDigit()
            .foregroundStyle(.white.opacity(model.phase == .paused ? 0.55 : 1))
            .padding(.leading, 6).padding(.trailing, 10)

            BarDivider(height: 28)
            if model.phase == .paused {
                IconButton(symbol: "play.fill", help: "Resume") { model.resume() }
            } else {
                IconButton(symbol: "pause.fill", help: "Pause") { model.pause() }.disabled(model.phase == .finishing)
            }
            IconButton(symbol: "arrow.counterclockwise", help: "Restart") { Task { await model.restart() } }
                .disabled(model.phase == .finishing)
            IconButton(symbol: "trash", help: "Discard") { Task { await model.discard() } }
                .disabled(model.phase == .finishing)
        }
    }

    private func errorPill(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(text).font(.system(size: 12)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            if model.permissionMissing {
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                .controlSize(.small)
            }
            Button { model.error = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: 520)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.11).opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.1)))
    }

    // MARK: menus (frame 2)

    private func showCameraMenu(at anchor: NSPoint) {
        let m = ClosureMenu()
        m.header("Camera")
        m.item("No camera", checked: model.selectedCamera == nil) { model.cameraID = nil }
        for c in model.cameras {
            m.item(c.localizedName, checked: model.cameraID == c.uniqueID) { model.cameraID = c.uniqueID }
        }
        m.addItem(.separator())
        m.header("Shape")
        m.item("Circle", checked: model.cameraShape == .circle) { model.cameraShape = .circle }
        m.item("Rounded square", checked: model.cameraShape == .rounded) { model.cameraShape = .rounded }
        m.addItem(.separator())
        m.header("Orientation")
        m.item("Same as camera", checked: model.cameraOrientation == .auto) { model.cameraOrientation = .auto }
        m.item("Landscape", checked: model.cameraOrientation == .landscape) { model.cameraOrientation = .landscape }
        m.item("Portrait", checked: model.cameraOrientation == .portrait) { model.cameraOrientation = .portrait }
        m.show(at: anchor)
    }

    private func showMicMenu(at anchor: NSPoint) {
        let m = ClosureMenu()
        m.header("Microphone")
        m.item("No microphone", checked: model.selectedMic == nil) { model.micID = nil }
        for c in model.mics {
            m.item(c.localizedName, checked: model.micID == c.uniqueID) { model.micID = c.uniqueID }
        }
        m.show(at: anchor)
    }

    private func showDeviceMenu(at anchor: NSPoint) {
        model.loadDevices()
        let m = ClosureMenu()
        m.header("iPhone or iPad")
        if model.iosDevices.isEmpty {
            m.note("Connect one with a cable and unlock it.")
            m.note("It can take a few seconds to show up.")
        } else {
            for d in model.iosDevices {
                m.item(d.localizedName, checked: model.selectedDevice?.uniqueID == d.uniqueID) { model.deviceID = d.uniqueID }
            }
        }
        m.show(at: anchor)
    }

    private func showSettingsMenu(at anchor: NSPoint) {
        let m = ClosureMenu()
        m.item("Count down 3, 2, 1 before recording", checked: model.countdownEnabled) { model.countdownEnabled.toggle() }
        m.item("Record shortcuts", checked: model.recordShortcuts) { model.recordShortcuts.toggle() }
        m.addItem(.separator())
        m.note("Saving to \(ReelProject.libraryFolder.lastPathComponent)")
        m.item("Change save folder…") { model.chooseSaveFolder() }
        m.item("Show recordings in Finder") { NSWorkspace.shared.open(ReelProject.libraryFolder) }
        m.addItem(.separator())
        m.note("⌘⇧2 starts and stops recording")
        m.addItem(.separator())
        m.item("Quit Reel") { NSApp.terminate(nil) }
        m.show(at: anchor)
    }

    // MARK: helpers

    /// "FaceTime HD Camera (Built-in)" -> "FaceTime HD Camera"
    static func short(_ name: String) -> String {
        name.replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)
    }

    static func clock(_ s: TimeInterval) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: pieces

private struct BarDivider: View {
    var height: CGFloat = 36
    var body: some View { Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: height) }
}

private struct IconButton: View {
    let symbol: String
    var size: CGFloat = 17
    var opacity: Double = 0.85
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(.white.opacity(enabled ? opacity : 0.3))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct ModeButton: View {
    let mode: CaptureMode
    let selected: Bool
    let action: (NSPoint) -> Void

    var body: some View {
        AnchoredButton(action: action) {
            VStack(spacing: 4) {
                Image(systemName: mode.symbol).font(.system(size: 18)).frame(height: 22)
                Text(mode.label).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white.opacity(selected ? 1 : 0.7))
            .padding(.vertical, 6).padding(.horizontal, 10)
            .frame(minWidth: 56)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(selected ? 0.14 : 0)))
            .contentShape(Rectangle())
        }
    }
}

private struct Chip: View {
    let symbol: String
    let label: String
    let on: Bool
    let chevron: Bool
    let action: (NSPoint) -> Void

    var body: some View {
        AnchoredButton(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 15)).frame(width: 20)
                Text(label).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if chevron { Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.7) }
            }
            .foregroundStyle(.white)
            .opacity(on ? 1 : 0.5)
            .padding(.vertical, 8).padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
    }
}

/// A plain button that also reports the screen point just under its bottom-left corner,
/// so a menu can open right below it.
private struct AnchoredButton<Label: View>: View {
    let action: (NSPoint) -> Void
    @ViewBuilder let label: () -> Label
    @State private var frame: CGRect = .zero

    var body: some View {
        Button { action(anchor()) } label: { label() }
            .buttonStyle(.plain)
            .background(GeometryReader { g in
                Color.clear.onAppear { frame = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { _, f in frame = f }
            })
    }

    private func anchor() -> NSPoint {
        guard let w = WindowManager.shared.bar else { return NSEvent.mouseLocation }
        let content = w.contentView?.frame.height ?? w.frame.height
        return NSPoint(x: w.frame.minX + frame.minX, y: w.frame.minY + content - frame.maxY - 6)
    }
}

/// NSMenu with closure items, popped up at a screen point.
final class ClosureMenu: NSMenu {
    private final class Item: NSMenuItem {
        var handler: (() -> Void)?
        @objc func fire() { handler?() }
    }

    init() { super.init(title: ""); autoenablesItems = false }
    required init(coder: NSCoder) { fatalError() }

    func item(_ title: String, checked: Bool = false, action: @escaping () -> Void) {
        let i = Item(title: title, action: #selector(Item.fire), keyEquivalent: "")
        i.target = i
        i.handler = action
        i.state = checked ? .on : .off
        addItem(i)
    }

    func header(_ title: String) {
        if #available(macOS 14.0, *) { addItem(.sectionHeader(title: title)) } else { note(title) }
    }

    func note(_ title: String) {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        addItem(i)
    }

    func show(at point: NSPoint) {
        popUp(positioning: nil, at: point, in: nil)
    }
}

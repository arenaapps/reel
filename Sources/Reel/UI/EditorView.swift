import SwiftUI
import AVKit
import UniformTypeIdentifiers

/// The editor (Figma: Reel > Editor, frame 1). No system title bar: the window controls share
/// the top bar with the way back to Recordings, the name, the size picker and Export.
struct EditorView: View {
    @StateObject private var model: EditorModel
    @State private var showExport = false
    @State private var editingName = false
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    init(project: ReelProject) {
        _model = StateObject(wrappedValue: EditorModel(project: project))
    }

    var editor: EditorModel { model }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                stage
                InspectorView(model: model)
                    .frame(width: 320)
                    .padding(.trailing, 12)
            }
            .frame(maxHeight: .infinity)
            timeline
        }
        .background(Palette.window)
        .environment(\.colorScheme, .dark)
        .toolbar { toolbarContent }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .focusEffectDisabled()
        .onDisappear { model.player.pause() }
        .background(EditorKeys(model: model, isTyping: editingName))
    }

    // MARK: top bar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 10) {
                Button { WindowManager.shared.showLibrary() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder").font(.system(size: 13))
                        Text("Recordings").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("/").foregroundStyle(.white.opacity(0.25))
                if editingName {
                    TextField("Name", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 240)
                        .focused($nameFocused)
                        .onSubmit(commitName)
                        .onExitCommand { editingName = false }
                        .onChange(of: nameFocused) { _, f in if !f { commitName() } }
                } else {
                    Button {
                        draftName = model.name
                        editingName = true
                        nameFocused = true
                    } label: {
                        HStack(spacing: 6) {
                            Text(model.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.5)
                        }
                        .foregroundStyle(.white)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Rename")
                }
            }
        }
        ToolbarItem(placement: .principal) {
            Segmented(items: AspectPreset.allCases.map { ($0, $0.label) }, selection: $model.settings.aspect)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: model.undo) { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo).help("Undo (⌘Z)")
                .keyboardShortcut(editingName ? nil : KeyboardShortcut("z", modifiers: .command))
            Button(action: model.redo) { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo).help("Redo (⇧⌘Z)")
                .keyboardShortcut(editingName ? nil : KeyboardShortcut("z", modifiers: [.command, .shift]))
            Button { showExport.toggle() } label: {
                Text("Export").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showExport, arrowEdge: .bottom) { ExportPanel(model: model) }
        }
    }

    private func commitName() {
        guard editingName else { return }
        model.rename(draftName)
        editingName = false
    }

    // MARK: preview

    private var stage: some View {
        GeometryReader { g in
            let aspect = max(model.previewAspect, 0.1)
            let fit = min(g.size.width / aspect, g.size.height)
            PlayerSurface(player: model.player)
                .frame(width: fit * aspect, height: fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .contentShape(Rectangle())
        .onTapGesture { model.togglePlay() }
    }

    // MARK: timeline

    @State private var timelineScale: Double = 1

    private var timeline: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button(action: model.togglePlay) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14)).foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(.white.opacity(0.1)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Play or pause (Space)")
                HStack(spacing: 6) {
                    Text(Self.clock(model.currentTime - model.settings.trimStart)).font(.system(size: 13, weight: .semibold))
                    Text("/ " + Self.clock(model.trimEnd - model.settings.trimStart)).font(.system(size: 13)).foregroundStyle(.white.opacity(0.45))
                }
                .monospacedDigit()
                Spacer()
                PillButton(title: "Add zoom", symbol: "plus.magnifyingglass", action: model.addZoom)
                HStack(spacing: 6) {
                    Button { timelineScale = max(1, timelineScale / 1.5) } label: { Image(systemName: "minus") }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
                    ReelSliderBare(value: $timelineScale, range: 1...8).frame(width: 70)
                    Button { timelineScale = min(8, timelineScale * 1.5) } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
                }
                .help("Timeline scale")
            }
            TimelineView(model: model, scale: timelineScale)
                .frame(height: 150)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.panel))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }

    static func clock(_ s: Double) -> String {
        let v = max(0, s)
        return String(format: "%d:%04.1f", Int(v) / 60, v.truncatingRemainder(dividingBy: 60))
    }
}

/// Track and knob only, no label.
struct ReelSliderBare: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var body: some View {
        GeometryReader { g in
            let frac = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2)).frame(height: 3)
                Circle().fill(.white).frame(width: 10, height: 10).offset(x: frac * (g.size.width - 10))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let f = min(max((v.location.x - 5) / max(g.size.width - 10, 1), 0), 1)
                value = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
            })
        }
        .frame(height: 14)
    }
}

/// Space, Delete, arrows and ⌘Z for the editor window. Ignored while a text field is being edited.
struct EditorKeys: NSViewRepresentable {
    let model: EditorModel
    let isTyping: Bool

    func makeNSView(context: Context) -> KeyView { KeyView() }
    func updateNSView(_ v: KeyView, context: Context) {
        v.model = model
        v.isTyping = isTyping
    }

    final class KeyView: NSView {
        weak var model: EditorModel?
        var isTyping = false
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, let model = self.model, e.window === self.window else { return e }
                if self.isTyping || (self.window?.firstResponder as? NSTextView)?.isEditable == true { return e }
                return MainActor.assumeIsolated { Self.handle(e, model) } ? nil : e
            }
        }

        @MainActor
        private static func handle(_ e: NSEvent, _ m: EditorModel) -> Bool {
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch e.keyCode {
            case 49 where mods.isEmpty:                       // space
                m.togglePlay(); return true
            case 51, 117:                                     // delete, forward delete
                guard m.selectedZoom != nil else { return false }
                m.deleteSelectedZoom(); return true
            case 53:                                          // esc
                guard m.selectedZoom != nil else { return false }
                m.selectedZoom = nil; return true
            case 123: m.step(frames: mods.contains(.shift) ? -30 : -1); return true   // left
            case 124: m.step(frames: mods.contains(.shift) ? 30 : 1); return true     // right
            default: return false
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.playerLayer.player = player
        return v
    }
    func updateNSView(_ v: PlayerLayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}

final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

/// Ruler, the clip with trim handles, click marks, zoom blocks and the playhead.
struct TimelineView: View {
    @ObservedObject var model: EditorModel
    var scale: Double = 1
    @State private var drag: DragState?

    enum DragKind { case move, start, end }
    struct DragState { let id: UUID; let kind: DragKind; let original: ZoomSegment }

    private let clipY: CGFloat = 32, clipH: CGFloat = 46, zoomY: CGFloat = 88, zoomH: CGFloat = 32

    var body: some View {
        GeometryReader { outer in
            ScrollView(.horizontal, showsIndicators: scale > 1) {
                let total = outer.size.width * CGFloat(scale)
                let w = total - 32
                let dur = max(model.duration, 0.1)
                let x: (Double) -> CGFloat = { 16 + CGFloat($0 / dur) * w }
                let t: (CGFloat) -> Double = { min(max(Double(($0 - 16) / w) * dur, 0), dur) }
                ZStack(alignment: .topLeading) {
                    // Empty space: click to move the playhead and clear the zoom selection.
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                            model.selectedZoom = nil
                            model.seek(to: t(v.location.x))
                        })
                    ruler(x: x, dur: dur, width: w)
                    // Clip
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.clip.opacity(0.16))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.clip.opacity(0.9), lineWidth: 1.5))
                        .overlay(alignment: .leading) {
                            Text("Recording · \(String(format: "%.1f", model.trimEnd - model.settings.trimStart)) s")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                                .padding(.leading, 18).lineLimit(1)
                        }
                        .frame(width: max(x(model.trimEnd) - x(model.settings.trimStart), 16), height: clipH)
                        .offset(x: x(model.settings.trimStart), y: clipY)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                            model.selectedZoom = nil
                            model.seek(to: t(v.location.x + x(model.settings.trimStart)))
                        })
                    // Clicks
                    ForEach(Array(model.project.events.clicks.enumerated()), id: \.offset) { _, c in
                        RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.7))
                            .frame(width: 2, height: 10)
                            .offset(x: x(c.t), y: clipY + clipH - 12)
                            .allowsHitTesting(false)
                    }
                    // Trim handles
                    trimHandle(at: x(model.settings.trimStart)) { v in
                        model.settings.trimStart = min(t(v.location.x), model.trimEnd - 0.5)
                    }
                    trimHandle(at: x(model.trimEnd) - 8) { v in
                        let e = max(t(v.location.x), model.settings.trimStart + 0.5)
                        model.settings.trimEnd = e >= dur - 0.01 ? nil : e
                    }
                    // Zooms
                    ForEach(model.settings.zooms) { z in
                        zoomBlock(z, x: x, width: max(x(z.end) - x(z.start), 10))
                    }
                    // Playhead
                    let px = x(model.currentTime)
                    Rectangle().fill(.white).frame(width: 2, height: 130).offset(x: px - 1, y: 20).allowsHitTesting(false)
                    RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 12, height: 12).offset(x: px - 6, y: 14)
                        .allowsHitTesting(false)
                }
                .frame(width: total, height: outer.size.height, alignment: .topLeading)
                .coordinateSpace(name: "timeline")
            }
        }
    }

    private func ruler(x: @escaping (Double) -> CGFloat, dur: Double, width: CGFloat) -> some View {
        // A tick every 1, 2, 5 or 10 s depending on how much room there is; labels every 5 ticks.
        let pxPerSec = width / CGFloat(dur)
        let step = [1.0, 2, 5, 10, 30].first { CGFloat($0) * pxPerSec >= 24 } ?? 60
        let ticks = Array(stride(from: 0.0, through: dur, by: step))
        return ZStack(alignment: .topLeading) {
            ForEach(Array(ticks.enumerated()), id: \.offset) { i, s in
                let major = i % 5 == 0
                Rectangle().fill(.white.opacity(major ? 0.35 : 0.18)).frame(width: 1, height: major ? 8 : 4).offset(x: x(s), y: 10)
                if major {
                    Text(String(format: "%d:%02d", Int(s) / 60, Int(s) % 60))
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.4))
                        .offset(x: x(s) + 4, y: 6)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func trimHandle(at xPos: CGFloat, onDrag: @escaping (DragGesture.Value) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Palette.clip)
            .frame(width: 8, height: clipH)
            .offset(x: xPos, y: clipY)
            .gesture(DragGesture(coordinateSpace: .named("timeline")).onChanged(onDrag))
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }

    private func zoomBlock(_ z: ZoomSegment, x: @escaping (Double) -> CGFloat, width: CGFloat) -> some View {
        let selected = model.selectedZoom == z.id
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.zoom.opacity(selected ? 0.55 : 0.28))
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white, lineWidth: selected ? 1.5 : 0)
            HStack(spacing: 5) {
                Image(systemName: "plus.magnifyingglass").font(.system(size: 11, weight: .medium))
                Text(String(format: "%.1f×", z.scale)).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.leading, 10)
            .lineLimit(1)
            .opacity(width > 56 ? 1 : 0)
            HStack {
                edge(z, .start, x: x)
                Spacer(minLength: 0)
                edge(z, .end, x: x)
            }
        }
        .frame(width: width, height: zoomH)
        .offset(x: x(z.start), y: zoomY)
        .onTapGesture { model.selectedZoom = z.id }
        .gesture(DragGesture(minimumDistance: 2).onChanged { v in
            apply(z, kind: .move, dx: v.translation.width, x: x)
        }.onEnded { _ in drag = nil })
        .help("Click to select. Delete removes it. Drag to move, drag the edges to resize.")
    }

    private func edge(_ z: ZoomSegment, _ kind: DragKind, x: @escaping (Double) -> CGFloat) -> some View {
        Rectangle().fill(Color.white.opacity(0.001)).frame(width: 8)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                apply(z, kind: kind, dx: v.translation.width, x: x)
            }.onEnded { _ in drag = nil })
    }

    private func apply(_ z: ZoomSegment, kind: DragKind, dx: CGFloat, x: @escaping (Double) -> CGFloat) {
        let pxPerSec = x(1) - x(0)
        guard pxPerSec > 0 else { return }
        let dt = Double(dx / pxPerSec)
        if drag?.id != z.id || drag?.kind != kind { drag = DragState(id: z.id, kind: kind, original: z) }
        guard let d = drag, let i = model.settings.zooms.firstIndex(where: { $0.id == z.id }) else { return }
        var n = d.original
        let dur = model.duration
        switch kind {
        case .move:
            let len = n.end - n.start
            n.start = min(max(0, d.original.start + dt), dur - len)
            n.end = n.start + len
        case .start:
            n.start = min(max(0, d.original.start + dt), n.end - 0.3)
        case .end:
            n.end = max(min(dur, d.original.end + dt), n.start + 0.3)
        }
        n.isAuto = false
        model.selectedZoom = z.id
        model.settings.zooms[i] = n
    }
}

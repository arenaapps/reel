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

    @StateObject private var viewport = TimelineViewport()

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
                    Text(Self.clock(model.timeline.output(at: model.currentTime))).font(.system(size: 13, weight: .semibold))
                    Text("/ " + Self.clock(model.timeline.length)).font(.system(size: 13)).foregroundStyle(.white.opacity(0.45))
                }
                .monospacedDigit()
                Spacer()
                PillButton(title: "Split", shortcut: "S", action: model.split)
                    .keyboardShortcut(editingName ? nil : KeyboardShortcut("b", modifiers: .command))
                    .help("Split at the playhead (S or ⌘B). With a zoom selected, splits that zoom.")
                PillButton(title: "Add zoom", symbol: "plus.magnifyingglass", action: model.addZoom)
                Spacer()
                HStack(spacing: 8) {
                    Button { viewport.zoom(by: 1 / 1.5, aroundTime: model.displayMap.output(at: model.currentTime), duration: model.displayMap.length) } label: { Image(systemName: "minus") }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
                        .keyboardShortcut("-", modifiers: .command)
                    ReelSliderBare(value: Binding(get: { log(viewport.scale) / log(TimelineViewport.maxScale) },
                                                  set: { viewport.setScale(pow(TimelineViewport.maxScale, $0), aroundTime: model.displayMap.output(at: model.currentTime), duration: model.displayMap.length) }),
                                   range: 0...1).frame(width: 110)
                    Button { viewport.zoom(by: 1.5, aroundTime: model.displayMap.output(at: model.currentTime), duration: model.displayMap.length) } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
                        .keyboardShortcut("=", modifiers: .command)
                    PillButton(title: "Fit", action: viewport.fit)
                        .keyboardShortcut("0", modifiers: .command)
                        .help("Show the whole recording (⌘0)")
                }
                .help("Zoom the timeline: pinch, ⌘ + scroll, ⌘= and ⌘−")
            }
            TimelineView(model: model, viewport: viewport)
                .frame(height: 190)
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
            case 1 where mods.isEmpty:                        // S
                m.split(); return true
            case 30 where mods.isEmpty:                       // ]
                guard m.selectedPiece != nil else { return false }
                m.stepSelectedPieceSpeed(1); return true
            case 33 where mods.isEmpty:                       // [
                guard m.selectedPiece != nil else { return false }
                m.stepSelectedPieceSpeed(-1); return true
            case 51, 117:                                     // delete, forward delete
                if m.selectedZoom != nil { m.deleteSelectedZoom(); return true }
                if m.selectedPiece != nil { m.toggleSelectedPieceCut(); return true }
                return false
            case 53:                                          // esc
                guard m.selectedZoom != nil || m.selectedPiece != nil else { return false }
                m.selectedZoom = nil; m.selectedPiece = nil; return true
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

/// Which part of the recording the timeline shows. `scale` 1 fits the whole recording;
/// `offset` is how far the content is scrolled, in points.
@MainActor
final class TimelineViewport: ObservableObject {
    static let maxScale = 24.0
    @Published var scale: Double = 1
    @Published var offset: CGFloat = 0
    var width: CGFloat = 1   // visible width, set by the view

    var contentWidth: CGFloat { width * CGFloat(scale) }
    /// Points per second of recording.
    func pxPerSec(_ duration: Double) -> CGFloat { (contentWidth - 32) / CGFloat(max(duration, 0.1)) }
    func x(_ t: Double, _ duration: Double) -> CGFloat { 16 + CGFloat(t) * pxPerSec(duration) - offset }
    func time(_ x: CGFloat, _ duration: Double) -> Double {
        min(max(Double((x + offset - 16) / pxPerSec(duration)), 0), duration)
    }

    func clamp() { offset = min(max(0, offset), max(0, contentWidth - width)) }
    func pan(_ dx: CGFloat) { offset += dx; clamp() }
    func fit() { scale = 1; offset = 0 }

    /// Changes the scale keeping the point at `anchorX` (visible coordinates) still.
    func setScale(_ new: Double, anchorX: CGFloat, duration: Double) {
        let t = time(anchorX, duration)
        scale = min(max(new, 1), Self.maxScale)
        offset = 16 + CGFloat(t) * pxPerSec(duration) - anchorX
        clamp()
    }
    func setScale(_ new: Double, aroundTime t: Double, duration: Double) {
        let ax = x(t, duration)
        setScale(new, anchorX: (0...width).contains(ax) ? ax : width / 2, duration: duration)
    }
    func zoom(by f: Double, aroundTime t: Double, duration: Double) { setScale(scale * f, aroundTime: t, duration: duration) }
    func zoom(by f: Double, anchorX: CGFloat, duration: Double) { setScale(scale * f, anchorX: anchorX, duration: duration) }
}

/// Ruler, the clip pieces with trim and split handles, click marks, zoom blocks and the playhead.
struct TimelineView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var viewport: TimelineViewport
    @State private var drag: DragState?
    @State private var splitDrag: (old: Double, current: Double)?

    enum DragKind { case move, start, end }
    struct DragState { let id: UUID; let kind: DragKind; let original: ZoomSegment }

    // The top 40 points hold the Speed bar for a selected piece.
    private let clipY: CGFloat = 72, clipH: CGFloat = 46, zoomY: CGFloat = 128, zoomH: CGFloat = 32

    var body: some View {
        GeometryReader { outer in
            // Cut pieces are gone from the axis entirely; x and t convert through it.
            let map = model.displayMap
            let dur = max(map.length, 0.1)
            let x: (Double) -> CGFloat = { viewport.x(map.output(at: $0), dur) }
            let t: (CGFloat) -> Double = { map.source(at: viewport.time($0, dur)) }
            let pieces = model.pieces
            ZStack(alignment: .topLeading) {
                // Empty space: click to move the playhead and clear the selection.
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        model.selectedZoom = nil
                        model.selectedPiece = nil
                        model.seek(to: t(v.location.x))
                    })
                ruler(x: { viewport.x($0, dur) }, dur: dur, width: viewport.contentWidth - 32)
                // Clip pieces
                ForEach(Array(pieces.enumerated()), id: \.offset) { _, p in
                    if !p.isCut { piece(p, x: x, t: t) }
                }
                // Clicks
                ForEach(Array(model.project.events.clicks.filter { abs(map.playable($0.t) - $0.t) < 1e-6 }.enumerated()), id: \.offset) { _, c in
                    RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.7))
                        .frame(width: 2, height: 10)
                        .offset(x: x(c.t), y: clipY + clipH - 12)
                        .allowsHitTesting(false)
                }
                // Trim handles at the outer edges
                trimHandle(at: x(model.settings.trimStart)) { v in
                    model.settings.trimStart = min(t(v.location.x), (model.pieces.first?.end ?? model.trimEnd) - 0.2)
                }
                trimHandle(at: x(model.trimEnd) - 8) { v in
                    let e = max(t(v.location.x), (model.pieces.last?.start ?? model.settings.trimStart) + 0.2)
                    model.settings.trimEnd = e >= dur - 0.01 ? nil : e
                }
                // Split handles between neighbouring kept pieces; a plain line where a cut was taken out.
                let joins = Array(zip(pieces, pieces.dropFirst()))
                ForEach(joins.filter { !$0.0.isCut && !$0.1.isCut }.map(\.1.start), id: \.self) { s in
                    splitHandle(at: s, x: x, t: t)
                }
                ForEach(joins.filter { $0.0.isCut && !$0.1.isCut && pieces.first(where: { !$0.isCut })?.start != $0.1.start }.map(\.1.start), id: \.self) { s in
                    RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.6)).frame(width: 2, height: clipH + 8)
                        .offset(x: x(s) - 1, y: clipY - 4).allowsHitTesting(false)
                }
                // Zooms
                ForEach(model.settings.zooms.filter { map.output(at: $0.end) - map.output(at: $0.start) > 0.05 }) { z in
                    zoomBlock(z, x: x, t: t, width: max(x(z.end) - x(z.start), 10))
                }
                // Playhead
                let px = x(model.currentTime)
                Rectangle().fill(.white).frame(width: 2, height: 130).offset(x: px - 1, y: 60).allowsHitTesting(false)
                RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 12, height: 12).offset(x: px - 6, y: 54)
                    .allowsHitTesting(false)
                // Where the view sits along the recording, when zoomed in
                if viewport.scale > 1.01 {
                    let w = outer.size.width - 32
                    let frac = outer.size.width / viewport.contentWidth
                    Capsule().fill(.white.opacity(0.08)).frame(width: w, height: 4).offset(x: 16, y: outer.size.height - 10)
                        .allowsHitTesting(false)
                    Capsule().fill(.white.opacity(0.35))
                        .frame(width: max(24, w * frac), height: 4)
                        .offset(x: 16 + w * viewport.offset / viewport.contentWidth, y: outer.size.height - 10)
                        .allowsHitTesting(false)
                }
                if let sel = model.selectedPieceInfo, !sel.isCut {
                    SpeedBar(speed: sel.speed) { model.setSelectedPieceSpeed($0) }
                        .fixedSize()
                        .alignmentGuide(.leading) { d in d.width / 2 - min(max(x(sel.mid), d.width / 2 + 8), outer.size.width - d.width / 2 - 8) }
                        .offset(y: 6)
                }
                ScrollCatcher(viewport: viewport, duration: dur).allowsHitTesting(false)
            }
            .frame(width: outer.size.width, height: outer.size.height, alignment: .topLeading)
            .clipped()
            .coordinateSpace(name: "timeline")
            .onAppear { viewport.width = outer.size.width; viewport.clamp() }
            .onChange(of: outer.size.width) { _, w in viewport.width = w; viewport.clamp() }
        }
    }

    private func piece(_ p: ClipPiece, x: @escaping (Double) -> CGFloat, t: @escaping (CGFloat) -> Double) -> some View {
        let selected = model.selectedPiece.map { abs($0 - p.start) < 1e-6 } ?? false
        let w = max(x(p.end) - x(p.start), 4)
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return ZStack(alignment: .topLeading) {
            shape.fill(Palette.clip.opacity(p.isCut ? 0.05 : 0.16))
            if p.isCut {
                shape.strokeBorder(Palette.clip.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            } else {
                shape.strokeBorder(Palette.clip.opacity(0.9), lineWidth: 1.5)
            }
            if selected { shape.strokeBorder(.white, lineWidth: 2) }
            if p.speed > 1.001 {
                // Faint chevrons along the bottom and a badge: this piece plays faster.
                HStack(spacing: 10) {
                    ForEach(0..<max(0, Int((w - 28) / 18)), id: \.self) { _ in
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                    }
                }
                .foregroundStyle(Palette.speed.opacity(0.45))
                .padding(.leading, 14).padding(.top, 28)
                .allowsHitTesting(false)
                Text(Self.speedLabel(p.speed))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Palette.speed.opacity(0.9)))
                    .frame(width: w - 8, alignment: .trailing).padding(.top, 8)
                    .opacity(w > 50 ? 1 : 0)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(p.isCut ? "Cut" : p.speed > 1.001
                     ? String(format: "%.1f s  →  %.1f s", p.end - p.start, p.playedLength)
                     : String(format: "%.1f s", p.end - p.start))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(p.isCut ? 0.45 : 0.85))
                if p.isCut {
                    Text("Skipped in the video").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                }
            }
            .lineLimit(1)
            .padding(.leading, 14).padding(.top, 8)
            .opacity(w > 60 ? 1 : 0)
        }
        .frame(width: w, height: clipH)
        .offset(x: x(p.start), y: clipY)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { v in
            model.selectedPiece = p.start
            model.seek(to: t(v.location.x))
        })
        .help("Click to select. Delete cuts it out of the video; [ and ] change its speed.")
    }

    static func speedLabel(_ r: Double) -> String {
        r == r.rounded() ? String(format: "%.0f×", r) : String(format: "%.1f×", r)
    }

    private func splitHandle(at s: Double, x: @escaping (Double) -> CGFloat, t: @escaping (CGFloat) -> Double) -> some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.001)).frame(width: 12)
            RoundedRectangle(cornerRadius: 1).fill(.white).frame(width: 2, height: clipH + 8)
        }
        .frame(width: 12, height: clipH + 8)
        .offset(x: x(s) - 6, y: clipY - 4)
        .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline")).onChanged { v in
            let old = splitDrag?.current ?? s
            let now = model.moveSplit(from: old, to: t(v.location.x))
            splitDrag = (s, now)
        }.onEnded { _ in splitDrag = nil })
        .help("Drag to move the split")
    }

    private func ruler(x: @escaping (Double) -> CGFloat, dur: Double, width: CGFloat) -> some View {
        // A tick every 1, 2, 5 or 10 s depending on how much room there is; labels every 5 ticks.
        let pxPerSec = width / CGFloat(dur)
        let step = [1.0, 2, 5, 10, 30].first { CGFloat($0) * pxPerSec >= 24 } ?? 60
        let ticks = Array(stride(from: 0.0, through: dur, by: step))
        return ZStack(alignment: .topLeading) {
            ForEach(Array(ticks.enumerated()), id: \.offset) { i, s in
                let major = i % 5 == 0
                Rectangle().fill(.white.opacity(major ? 0.35 : 0.18)).frame(width: 1, height: major ? 8 : 4).offset(x: x(s), y: 50)
                if major {
                    Text(String(format: "%d:%02d", Int(s) / 60, Int(s) % 60))
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.4))
                        .offset(x: x(s) + 4, y: 46)
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

    private func zoomBlock(_ z: ZoomSegment, x: @escaping (Double) -> CGFloat, t: @escaping (CGFloat) -> Double, width: CGFloat) -> some View {
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
        .gesture(SpatialTapGesture(coordinateSpace: .named("timeline")).onEnded { v in
            // Select it and put the playhead where it was clicked, ready for S to split it there.
            model.selectedZoom = z.id
            model.seek(to: t(v.location.x))
        })
        .gesture(DragGesture(minimumDistance: 2).onChanged { v in
            apply(z, kind: .move, dx: v.translation.width, x: x)
        }.onEnded { _ in drag = nil })
        .help("Click to select. S splits it at the playhead, Delete removes it. Drag to move, drag the edges to resize.")
    }

    private func edge(_ z: ZoomSegment, _ kind: DragKind, x: @escaping (Double) -> CGFloat) -> some View {
        Rectangle().fill(Color.white.opacity(0.001)).frame(width: 8)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                apply(z, kind: kind, dx: v.translation.width, x: x)
            }.onEnded { _ in drag = nil })
    }

    private func apply(_ z: ZoomSegment, kind: DragKind, dx: CGFloat, x: @escaping (Double) -> CGFloat) {
        // Work on the timeline's axis (cuts removed), then map back to recording time.
        let map = model.displayMap
        let dur = map.length
        let pxPerSec = viewport.pxPerSec(dur)
        guard pxPerSec > 0 else { return }
        let dt = Double(dx / pxPerSec)
        if drag?.id != z.id || drag?.kind != kind { drag = DragState(id: z.id, kind: kind, original: z) }
        guard let d = drag, let i = model.settings.zooms.firstIndex(where: { $0.id == z.id }) else { return }
        var n = d.original
        let s0 = map.output(at: d.original.start), e0 = map.output(at: d.original.end)
        var s1 = s0, e1 = e0
        switch kind {
        case .move:
            let len = e0 - s0
            s1 = min(max(0, s0 + dt), dur - len)
            e1 = s1 + len
        case .start:
            s1 = min(max(0, s0 + dt), e0 - 0.3)
        case .end:
            e1 = max(min(dur, e0 + dt), s0 + 0.3)
        }
        n.start = map.source(at: s1)
        n.end = map.source(at: e1)
        n.isAuto = false
        model.selectedZoom = z.id
        model.settings.zooms[i] = n
    }
}

/// Turns trackpad pinches and ⌘ + scroll over the timeline into timeline zoom, and other
/// scrolling into moving along it when zoomed in.
struct ScrollCatcher: NSViewRepresentable {
    let viewport: TimelineViewport
    let duration: Double

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ v: CatcherView, context: Context) { v.viewport = viewport; v.duration = duration }

    final class CatcherView: NSView {
        weak var viewport: TimelineViewport?
        var duration: Double = 1
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] e in
                guard let self, let vp = self.viewport, e.window === self.window else { return e }
                let p = self.convert(e.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return e }
                let anchor = p.x
                return MainActor.assumeIsolated {
                    if e.type == .magnify {
                        vp.zoom(by: 1 + Double(e.magnification) * 1.5, anchorX: anchor, duration: self.duration)
                        return nil
                    }
                    let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 8
                    let dx = e.hasPreciseScrollingDeltas ? e.scrollingDeltaX : e.scrollingDeltaX * 8
                    if e.modifierFlags.contains(.command) {
                        vp.zoom(by: exp(Double(dy) * 0.01), anchorX: anchor, duration: self.duration)
                        return nil
                    }
                    guard vp.scale > 1.01 else { return e }
                    vp.pan(-(abs(dx) > abs(dy) ? dx : dy))
                    return nil
                }
            }
        }
        // Not flipped-aware in SwiftUI's sense, but only x is used.
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

/// 1x to 8x for the selected piece, floating above it on the timeline.
struct SpeedBar: View {
    let speed: Double
    let set: (Double) -> Void
    var body: some View {
        HStack(spacing: 4) {
            Text("Speed").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 4)
            ForEach(EditorModel.speedSteps, id: \.self) { r in
                let on = abs(r - speed) < 1e-6
                Button { set(r) } label: {
                    Text(TimelineView.speedLabel(r))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(on ? Palette.ink : .white.opacity(0.8))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? Color.white : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.raised))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.4), radius: 8, y: 6)
        .help("Speed of the selected piece ([ slower, ] faster)")
    }
}

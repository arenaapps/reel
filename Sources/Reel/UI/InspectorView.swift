import SwiftUI
import UniformTypeIdentifiers

/// Side panel with five tabs (Figma: Reel > Editor, frame 1).
struct InspectorView: View {
    @ObservedObject var model: EditorModel
    @State private var tab: Tab = .background
    @State private var backgroundKind: BackgroundKind = .gradient
    @State private var naming = false
    @State private var newLookName = ""

    enum Tab: String, CaseIterable, Identifiable {
        case background = "Background", cursor = "Cursor", zoom = "Zoom", camera = "Camera", audio = "Audio"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .background: return "photo"
            case .cursor: return "cursorarrow"
            case .zoom: return "plus.magnifyingglass"
            case .camera: return "video"
            case .audio: return "speaker.wave.2"
            }
        }
    }

    enum BackgroundKind: Hashable { case gradient, colour, image }

    static let gradients: [(RGBA, RGBA)] = [
        (RGBA(r: 0.40, g: 0.33, b: 0.95), RGBA(r: 0.95, g: 0.45, b: 0.62)),
        (RGBA(r: 0.06, g: 0.46, b: 0.84), RGBA(r: 0.40, g: 0.86, b: 0.86)),
        (RGBA(r: 0.98, g: 0.62, b: 0.25), RGBA(r: 0.93, g: 0.27, b: 0.35)),
        (RGBA(r: 0.12, g: 0.13, b: 0.18), RGBA(r: 0.30, g: 0.32, b: 0.42)),
        (RGBA(r: 0.20, g: 0.70, b: 0.45), RGBA(r: 0.85, g: 0.92, b: 0.40)),
        (RGBA(r: 0.92, g: 0.90, b: 0.86), RGBA(r: 0.78, g: 0.80, b: 0.86)),
        (RGBA(r: 0.10, g: 0.20, b: 0.45), RGBA(r: 0.55, g: 0.25, b: 0.65)),
        (RGBA(r: 0.95, g: 0.80, b: 0.55), RGBA(r: 0.90, g: 0.55, b: 0.45))
    ]
    static let solids: [RGBA] = [
        RGBA(r: 0.07, g: 0.07, b: 0.08), RGBA(r: 0.96, g: 0.96, b: 0.95), RGBA(r: 0.36, g: 0.33, b: 0.95),
        RGBA(r: 0.95, g: 0.40, b: 0.35), RGBA(r: 0.20, g: 0.65, b: 0.45), RGBA(r: 0.98, g: 0.80, b: 0.30)
    ]

    var body: some View {
        VStack(spacing: 0) {
            lookBar
            HStack(spacing: 0) {
                ForEach(Tab.allCases) { t in
                    Button { tab = t } label: {
                        VStack(spacing: 4) {
                            Image(systemName: t.symbol).font(.system(size: 15)).frame(height: 18)
                            Text(t.rawValue).font(.system(size: 10, weight: .medium))
                                .lineLimit(1).fixedSize()
                        }
                        .foregroundStyle(.white.opacity(tab == t ? 1 : 0.55))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(tab == t ? 0.1 : 0)))
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 12)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch tab {
                    case .background: background
                    case .cursor: cursor
                    case .zoom: zoom
                    case .camera: camera
                    case .audio: audio
                    }
                }
                .padding(.top, 20)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.panel))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.06)))
        .onAppear {
            switch model.settings.background {
            case .gradient: backgroundKind = .gradient
            case .solid: backgroundKind = .colour
            case .image: backgroundKind = .image
            }
        }
    }

    // MARK: tabs

    @ViewBuilder private var background: some View {
        SectionLabel("Wallpaper")
        Segmented(items: [(BackgroundKind.gradient, "Gradient"), (.colour, "Colour"), (.image, "Image")], selection: $backgroundKind, fill: true)
        switch backgroundKind {
        case .gradient:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(Array(Self.gradients.enumerated()), id: \.offset) { _, g in
                    swatch(LinearGradient(colors: [g.0.color, g.1.color], startPoint: .topLeading, endPoint: .bottomTrailing),
                           selected: isSelected(g)) { model.settings.background = .gradient(g.0, g.1, angle: 135) }
                }
            }
        case .colour:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(Array(Self.solids.enumerated()), id: \.offset) { _, c in
                    swatch(c.color, selected: model.settings.background == .solid(c)) { model.settings.background = .solid(c) }
                }
                ColorPicker("", selection: Binding(
                    get: { if case .solid(let c) = model.settings.background { return c.color }; return .white },
                    set: { model.settings.background = .solid(RGBA($0)) }))
                    .labelsHidden()
                    .frame(height: 44)
            }
        case .image:
            if case .image(let path) = model.settings.background {
                Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            PillButton(title: "Choose image…", symbol: "photo.on.rectangle", action: pickImage)
        }
        SectionLabel("Frame")
        ReelSlider(title: "Padding", value: $model.settings.padding, range: 0...0.25) { "\(Int(($0 * 100).rounded()))%" }
        ReelSlider(title: "Corners", value: $model.settings.cornerRadius, range: 0...48)
        ReelSlider(title: "Shadow", value: $model.settings.shadow, range: 0...1) { "\(Int(($0 * 100).rounded()))%" }
    }

    @ViewBuilder private var cursor: some View {
        SectionLabel("Cursor")
        PanelToggle(title: "Show cursor", isOn: $model.settings.showCursor)
        ReelSlider(title: "Size", value: $model.settings.cursorScale, range: 0.8...3) { String(format: "%.1f×", $0) }
        ReelSlider(title: "Smoothing", value: $model.settings.cursorSmoothing, range: 0...1) { "\(Int(($0 * 100).rounded()))%" }
        PanelToggle(title: "Click highlight", isOn: $model.settings.clickEffect)
        PanelToggle(title: "Hide when still", isOn: $model.settings.hideIdleCursor)
        SectionLabel("Keys")
        PanelToggle(title: "Show shortcuts", isOn: $model.settings.showKeys)
        Segmented(items: [(KeysPosition.bottom, "Bottom"), (.top, "Top")], selection: $model.settings.keysPosition, fill: true)
        ReelSlider(title: "Size", value: $model.settings.keysScale, range: 0.5...1.5) { "\(Int(($0 * 100).rounded()))%" }
        Text(model.project.events.keys.isEmpty
             ? "No shortcuts in this recording. Tick Record shortcuts in the bar's settings menu before recording. Only keys pressed with ⌘, ⌃ or ⌥, plus Esc, Return, Tab and the arrows, are saved. Plain typing is never stored."
             : "Only keys pressed with ⌘, ⌃ or ⌥, plus Esc, Return, Tab and the arrows, were saved. Plain typing is never stored.")
            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: looks

    private var lookBar: some View {
        HStack(spacing: 8) {
            Text("Look").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            Menu {
                Toggle(LookStore.builtInName, isOn: Binding(get: { model.currentLookName == LookStore.builtInName },
                                                            set: { _ in model.applyLook(named: LookStore.builtInName) }))
                ForEach(model.looks) { l in
                    Toggle(l.name, isOn: Binding(get: { model.currentLookName == l.name },
                                                 set: { _ in model.applyLook(named: l.name) }))
                }
                Divider()
                Button("Save current look…") { newLookName = ""; naming = true }
                if let name = model.currentLookName {
                    Toggle("Use for new recordings", isOn: Binding(get: { model.lookForNew == name || (model.lookForNew == nil && name == LookStore.builtInName) },
                                                                   set: { on in model.setLookForNew(on ? name : nil) }))
                    if name != LookStore.builtInName {
                        Button("Delete \(name)") { model.deleteLook(named: name) }
                    }
                }
            } label: {
                Text(model.currentLookName ?? "Custom").font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .focusEffectDisabled()
            .fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.raised))
            Spacer()
        }
        .padding(.top, 14)
        .alert("Save look", isPresented: $naming) {
            TextField("Name", text: $newLookName)
            Button("Save") { model.saveLook(named: newLookName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the background, frame, aspect, cursor, click ring, zoom speed, motion blur, camera bubble and keys.")
        }
    }

    @ViewBuilder private var zoom: some View {
        SectionLabel("All zooms")
        ReelSlider(title: "Speed", value: $model.settings.zoomSpeed, range: 0...1) { "\(Int(($0 * 100).rounded()))%" }
        ReelSlider(title: "Motion blur", value: $model.settings.motionBlur, range: 0...1) { "\(Int(($0 * 100).rounded()))%" }
        HStack(spacing: 8) {
            PillButton(title: "Add zoom", symbol: "plus.magnifyingglass", action: model.addZoom)
            PillButton(title: "Rebuild from clicks", symbol: "arrow.clockwise", action: model.regenerateAutoZooms)
        }
        SectionLabel("Selected zoom")
        if let id = model.selectedZoom, let z = model.binding(for: id) {
            ReelSlider(title: "Zoom level", value: z.scale, range: 1.2...4) { String(format: "%.1f×", $0) }
            PanelToggle(title: "Follow cursor", isOn: Binding(
                get: { z.wrappedValue.focusX == nil },
                set: { follow in
                    if follow { z.wrappedValue.focusX = nil; z.wrappedValue.focusY = nil }
                    else { z.wrappedValue.focusX = 0.5; z.wrappedValue.focusY = 0.5 }
                }))
            if z.wrappedValue.focusX != nil {
                ReelSlider(title: "Focus across", value: Binding(get: { z.wrappedValue.focusX ?? 0.5 }, set: { z.wrappedValue.focusX = $0 }), range: 0...1) { "\(Int(($0 * 100).rounded()))%" }
                ReelSlider(title: "Focus down", value: Binding(get: { z.wrappedValue.focusY ?? 0.5 }, set: { z.wrappedValue.focusY = $0 }), range: 0...1) { "\(Int(($0 * 100).rounded()))%" }
            }
            PillButton(title: "Delete zoom", symbol: "trash", action: model.deleteSelectedZoom)
        } else {
            Text("Click a zoom on the timeline to change it. Delete removes the selected one.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var camera: some View {
        SectionLabel("Camera")
        if model.project.document.recording.cameraFile == nil {
            Text("No camera was recorded.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
        } else {
            PanelToggle(title: "Show camera", isOn: $model.settings.showCamera)
            SectionLabel("Corner")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach([(CameraCorner.topLeft, "Top left"), (.topRight, "Top right"), (.bottomLeft, "Bottom left"), (.bottomRight, "Bottom right")], id: \.0) { c in
                    choice(c.1, selected: model.settings.cameraCorner == c.0) { model.settings.cameraCorner = c.0 }
                }
            }
            SectionLabel("Shape")
            Segmented(items: [(CameraShape.circle, "Circle"), (.rounded, "Rounded square")], selection: $model.settings.cameraShape, fill: true)
            ReelSlider(title: "Size", value: $model.settings.cameraSize, range: 0.1...0.45) { "\(Int(($0 * 100).rounded()))%" }
        }
    }

    @ViewBuilder private var audio: some View {
        SectionLabel("Audio")
        let rec = model.project.document.recording
        if rec.micFile != nil {
            ReelSlider(title: "Microphone", value: $model.settings.micVolume, range: 0...2) { "\(Int(($0 * 100).rounded()))%" }
        }
        if rec.hasSystemAudio {
            ReelSlider(title: "System audio", value: $model.settings.systemVolume, range: 0...2) { "\(Int(($0 * 100).rounded()))%" }
        }
        if rec.micFile != nil {
            SectionLabel("Timing")
            VStack(spacing: 6) {
                ReelSlider(title: "Mic timing", value: $model.settings.micShift, range: -0.5...0.5) { v in
                    let ms = Int((v * 1000).rounded())
                    return ms == 0 ? "0 ms" : String(format: "%+d ms", ms)
                }
                HStack {
                    Text("Earlier"); Spacer(); Text("Later")
                }
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded { model.settings.micShift = 0 })
            Text("Moves your voice against the video, up to half a second either way. Use it when a Bluetooth mic arrives late. Double-click resets it to 0.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        if rec.micFile == nil && !rec.hasSystemAudio {
            Text("No audio was recorded.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
        }
    }

    // MARK: helpers

    private func swatch<S: ShapeStyle>(_ fill: S, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill)
                .frame(height: 44)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(selected ? 1 : 0.08), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(selected ? 1 : 0.6))
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(selected ? 0.14 : 0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func isSelected(_ g: (RGBA, RGBA)) -> Bool {
        if case .gradient(let a, let b, _) = model.settings.background { return a == g.0 && b == g.1 }
        return false
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.background = .image(url.path)
        }
    }
}

extension RGBA {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent, a: ns.alphaComponent)
    }
}

/// Export panel under the Export button (Figma: Reel > Editor, frame 2).
struct ExportPanel: View {
    @ObservedObject var model: EditorModel
    @State private var options = ExportOptions()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            field("Format") {
                Segmented(items: [(ExportFormat.mp4, "MP4"), (.gif, "GIF")], selection: $options.format, fill: true)
            }
            if options.format == .mp4 {
                field("Quality") {
                    Segmented(items: ExportQuality.allCases.map { ($0, $0.label) }, selection: $options.quality, fill: true)
                }
                field("Frame rate") {
                    Segmented(items: [(Int32(30), "30 fps"), (Int32(60), "60 fps")], selection: $options.fps, fill: true)
                }
            } else {
                field("Width") {
                    Segmented(items: [(CGFloat(640), "640 px"), (CGFloat(960), "960 px"), (CGFloat(1280), "1280 px")], selection: $options.gifWidth, fill: true)
                }
            }
            Text(summary).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            if let p = model.exportProgress {
                VStack(spacing: 8) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.12))
                            Capsule().fill(.white).frame(width: g.size.width * p)
                        }
                    }
                    .frame(height: 6)
                    HStack {
                        Text("Exporting… \(Int(p * 100))%").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        Button("Cancel", action: model.cancelExport).buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    }
                }
            } else {
                PillButton(title: "Export to Desktop…", prominent: true, action: choose)
                if let url = model.lastExport {
                    HStack {
                        Text("Saved \(url.lastPathComponent)").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        Spacer()
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            if let e = model.exportError { Text(e).font(.system(size: 12)).foregroundStyle(Palette.red) }
        }
        .padding(16)
        .frame(width: 340)
        .background(Palette.raised)
        .environment(\.colorScheme, .dark)
    }

    private var summary: String {
        let duration = String(format: "%.1f s", model.timeline.length)
        if options.format == .mp4 {
            let s = model.outputSize(shortSide: CGFloat(options.quality.rawValue))
            return "\(Int(s.width)) × \(Int(s.height)) · \(duration)"
        }
        return "\(Int(options.gifWidth)) px wide · \(duration)"
    }

    private func field<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            content()
        }
    }

    private func choose() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [options.format == .mp4 ? .mpeg4Movie : .gif]
        panel.nameFieldStringValue = model.name + (options.format == .mp4 ? ".mp4" : ".gif")
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url {
            model.export(options: options, to: url)
        }
    }
}

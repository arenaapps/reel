import SwiftUI
import AppKit
import AVFoundation
import Combine

@MainActor
final class EditorModel: ObservableObject {
    let project: ReelProject
    let player = AVPlayer()
    @Published var settings: EditSettings
    @Published var currentTime: Double = 0      // source time (seconds into the recording)
    @Published var isPlaying = false
    @Published var selectedZoom: UUID? { didSet { if selectedZoom != nil { selectedPiece = nil } } }
    /// Start time of the selected clip piece.
    @Published var selectedPiece: Double? { didSet { if selectedPiece != nil { selectedZoom = nil } } }
    @Published var exportProgress: Double?
    @Published var exportError: String?
    @Published var lastExport: URL?
    @Published var name: String
    @Published var sourceSize: CGSize = CGSize(width: 1920, height: 1080)
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// Settings as last saved; undo steps between these snapshots.
    private var committed: EditSettings
    private var undoStack: [EditSettings] = [] { didSet { canUndo = !undoStack.isEmpty } }
    private var redoStack: [EditSettings] = [] { didSet { canRedo = !redoStack.isEmpty } }

    private var builtTimeline: EditTimeline?
    private var rebuildTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var bag: Set<AnyCancellable> = []
    private var exportTask: Task<Void, Never>?

    var duration: Double { project.document.recording.duration }
    var trimEnd: Double { min(settings.trimEnd ?? duration, duration) }
    var timeline: EditTimeline { EditTimeline(settings, duration: duration) }
    var pieces: [ClipPiece] { settings.pieces(duration: duration) }
    /// The timeline's own axis: the recording with every cut taken out (trimmed ends stay visible).
    var displayMap: EditTimeline {
        var s = settings
        s.trimStart = 0
        s.trimEnd = nil
        return EditTimeline(s, duration: duration)
    }

    init(project: ReelProject) {
        self.project = project
        settings = project.document.settings
        committed = project.document.settings
        name = project.document.name
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = (self.builtTimeline ?? self.timeline).source(at: t.seconds)
                self.isPlaying = self.player.rate != 0
            }
        }
        $settings
            .dropFirst()
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] s in self?.settingsChanged(s) }
            .store(in: &bag)
        rebuild(seekTo: 0)
        // The periodic observer stops firing at the end, so clear the playing state here.
        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] n in
                guard let self, (n.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.isPlaying = false
            }.store(in: &bag)
        player.publisher(for: \.currentItem?.status).sink { st in
            Log.render.info("player item status \(String(describing: st?.rawValue), privacy: .public)")
        }.store(in: &bag)
        player.publisher(for: \.currentItem?.error).sink { e in
            if let e { Log.render.error("player item error \(e.localizedDescription, privacy: .public)") }
        }.store(in: &bag)
    }

    private func settingsChanged(_ s: EditSettings) {
        // Changes that arrive close together (a slider drag) settle into one undo step.
        if s != committed {
            undoStack.append(committed)
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack.removeAll()
            committed = s
        }
        project.document.settings = s
        try? project.save()
        rebuild(seekTo: currentTime)
    }

    private func previewSize(source: CGSize) -> CGSize {
        RenderSizing.size(aspect: settings.aspect, source: source, shortSide: 720)
    }

    func rebuild(seekTo source: Double) {
        rebuildTask?.cancel()
        let s = settings
        rebuildTask = Task {
            do {
                let src = try await CompositionBuilder.sourceSize(of: project)
                if sourceSize != src { sourceSize = src }
                let built = try await CompositionBuilder.build(project: project, settings: s, renderSize: previewSize(source: src), fps: 30)
                if Task.isCancelled { return }
                let mapped = EditTimeline(s, duration: duration)
                if let item = player.currentItem, let b = builtTimeline, b == mapped {
                    // Same tracks, only the look changed: swap the drawing in place.
                    item.videoComposition = built.videoComposition
                    item.audioMix = built.audioMix
                } else {
                    let item = AVPlayerItem(asset: built.composition)
                    item.videoComposition = built.videoComposition
                    item.audioMix = built.audioMix
                    player.replaceCurrentItem(with: item)
                    builtTimeline = mapped
                    seek(to: source)
                }
                Log.render.info("preview rebuilt \(Int(built.videoComposition.renderSize.width))x\(Int(built.videoComposition.renderSize.height))")
            } catch {
                Log.render.error("preview rebuild failed: \(error.localizedDescription, privacy: .public)")
                exportError = error.localizedDescription
            }
        }
    }

    // MARK: undo

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(settings)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(settings)
        restore(next)
    }

    private func restore(_ s: EditSettings) {
        committed = s
        settings = s
        if let id = selectedZoom, !s.zooms.contains(where: { $0.id == id }) { selectedZoom = nil }
        if let sp = selectedPiece, !pieces.contains(where: { abs($0.start - sp) < 1e-6 }) { selectedPiece = nil }
    }

    // MARK: name and shape

    func rename(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != project.document.name else { name = project.document.name; return }
        project.document.name = trimmed
        name = trimmed
        try? project.save()
    }

    /// Width over height of the finished video, for sizing the preview.
    var previewAspect: CGFloat { settings.aspect.ratio(source: sourceSize) }

    /// Output size for a quality, for the export panel.
    func outputSize(shortSide: CGFloat) -> CGSize {
        RenderSizing.size(aspect: settings.aspect, source: sourceSize, shortSide: shortSide)
    }

    // MARK: playback

    /// Moves the playhead by whole frames (30 fps), pausing first.
    func step(frames: Int) {
        if player.rate != 0 { player.pause() }
        seek(to: currentTime + Double(frames) / 30)
    }

    /// Moves the playhead to a moment of the recording. Inside a cut it lands where the video resumes.
    func seek(to source: Double) {
        let map = timeline
        let out = map.output(at: min(max(source, settings.trimStart), trimEnd))
        currentTime = map.source(at: out)
        player.seek(to: CMTime(seconds: out, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlay() {
        if player.rate != 0 { player.pause() } else {
            let map = timeline
            if map.output(at: currentTime) >= map.length - 0.05 { seek(to: map.source(at: 0)) }
            player.play()
        }
        isPlaying = player.rate != 0
    }

    // MARK: split and cut

    /// Splits at the playhead: the selected zoom if the playhead is inside it, otherwise the clip.
    func split() {
        let t = currentTime
        if let id = selectedZoom, let i = settings.zooms.firstIndex(where: { $0.id == id }) {
            let z = settings.zooms[i]
            guard t > z.start + 0.2, t < z.end - 0.2 else { NSSound.beep(); return }
            var first = z, second = z
            first.end = t
            first.isAuto = false
            second.id = UUID()
            second.start = t
            second.isAuto = false
            settings.zooms[i] = first
            settings.zooms.insert(second, at: i + 1)
            selectedZoom = second.id
            return
        }
        guard t > settings.trimStart + 0.1, t < trimEnd - 0.1,
              !settings.splits.contains(where: { abs($0 - t) < 0.1 }) else { return }
        settings.splits.append(t)
        // A split inside a cut leaves both halves cut.
        selectedPiece = nil
    }

    func selectPiece(at t: Double) {
        selectedPiece = pieces.first { $0.start <= t && t <= $0.end }?.start
    }

    /// Delete on a piece cuts it out of the video; on a piece already cut, brings it back.
    func toggleSelectedPieceCut() {
        guard let start = selectedPiece, let p = pieces.first(where: { abs($0.start - start) < 1e-6 }) else { return }
        if p.isCut {
            settings.cuts.removeAll { $0.start <= p.mid && p.mid <= $0.end }
        } else {
            // Keep at least one piece in the video.
            guard pieces.filter({ !$0.isCut }).count > 1 else { NSSound.beep(); return }
            settings.cuts.append(CutRange(start: p.start, end: p.end))
            selectedPiece = nil
        }
        seek(to: currentTime)
    }

    /// Drags the split at `old` to `new`, keeping any cut that ends or starts there attached.
    func moveSplit(from old: Double, to new: Double) -> Double {
        let edges = [settings.trimStart] + settings.splits.filter { abs($0 - old) > 1e-6 }.sorted() + [trimEnd]
        let lo = edges.last { $0 < old } ?? settings.trimStart
        let hi = edges.first { $0 > old } ?? trimEnd
        let v = min(max(new, lo + 0.2), hi - 0.2)
        guard let i = settings.splits.firstIndex(where: { abs($0 - old) < 1e-6 }) else { return old }
        settings.splits[i] = v
        for j in settings.cuts.indices {
            if abs(settings.cuts[j].start - old) < 1e-6 { settings.cuts[j].start = v }
            if abs(settings.cuts[j].end - old) < 1e-6 { settings.cuts[j].end = v }
        }
        if let sp = selectedPiece, abs(sp - old) < 1e-6 { selectedPiece = v }
        return v
    }

    // MARK: zooms

    func addZoom() {
        let start = min(currentTime, max(0, duration - 1))
        let z = ZoomSegment(start: start, end: min(duration, start + 2.5), scale: 2, isAuto: false)
        settings.zooms.append(z)
        selectedZoom = z.id
    }

    func deleteSelectedZoom() {
        settings.zooms.removeAll { $0.id == selectedZoom }
        selectedZoom = nil
    }

    func regenerateAutoZooms() {
        let manual = settings.zooms.filter { !$0.isAuto }
        let auto = ZoomPlanner.autoZooms(clicks: project.events.clicks, duration: duration)
            .filter { a in !manual.contains { $0.start < a.end && a.start < $0.end } }
        settings.zooms = manual + auto
    }

    func binding(for id: UUID) -> Binding<ZoomSegment>? {
        guard settings.zooms.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.settings.zooms.first { $0.id == id } ?? ZoomSegment(start: 0, end: 0) },
            set: { new in
                if let i = self.settings.zooms.firstIndex(where: { $0.id == id }) { self.settings.zooms[i] = new }
            })
    }

    // MARK: export

    func export(options: ExportOptions, to url: URL) {
        exportError = nil
        exportProgress = 0
        project.document.settings = settings
        try? project.save()
        exportTask = Task {
            do {
                try await Exporter.export(project: project, options: options, to: url) { p in
                    Task { @MainActor in self.exportProgress = p }
                }
                lastExport = url
            } catch is CancellationError {
            } catch {
                exportError = error.localizedDescription
            }
            exportProgress = nil
        }
    }

    func cancelExport() {
        exportTask?.cancel()
        exportProgress = nil
    }
}

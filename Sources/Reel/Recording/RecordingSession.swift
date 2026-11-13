import AppKit
import AVFoundation
import ScreenCaptureKit

enum CaptureSource: Identifiable {
    case display(SCDisplay)
    case window(SCWindow)
    case area(SCDisplay, CGRect)        // rect in global CG coordinates (top-left origin), points
    case device(AVCaptureDevice)        // a connected iPhone or iPad

    var id: String {
        switch self {
        case .display(let d): return "d\(d.displayID)"
        case .window(let w): return "w\(w.windowID)"
        case .area(let d, let r): return "a\(d.displayID)-\(r)"
        case .device(let d): return "i\(d.uniqueID)"
        }
    }

    /// Area on the Mac's screens in global CG coordinates, or nil for a phone.
    var frame: CGRect? {
        switch self {
        case .display(let d): return d.frame
        case .window(let w): return w.frame
        case .area(_, let r): return r
        case .device: return nil
        }
    }
}

enum Sources {
    static func load() async throws -> (displays: [SCDisplay], windows: [SCWindow]) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let me = Bundle.main.bundleIdentifier
        let windows = content.windows.filter {
            $0.isOnScreen && $0.windowLayer == 0 && $0.frame.width > 120 && $0.frame.height > 120
                && $0.owningApplication?.bundleIdentifier != me
                && !($0.owningApplication?.applicationName ?? "").isEmpty
        }
        return (content.displays, windows)
    }

    static func scale(for frame: CGRect) -> CGFloat {
        // Match the NSScreen whose CG frame contains the centre of the area.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let centre = CGPoint(x: frame.midX, y: primaryHeight - frame.midY)
        return NSScreen.screens.first { $0.frame.contains(centre) }?.backingScaleFactor ?? 2
    }

    static func evenPixels(_ frame: CGRect) -> CGSize {
        let scale = scale(for: frame)
        // HEVC wants even dimensions.
        return CGSize(width: (frame.width * scale / 2).rounded(.down) * 2,
                      height: (frame.height * scale / 2).rounded(.down) * 2)
    }
}

struct RecordingOptions {
    var source: CaptureSource
    var camera: AVCaptureDevice?
    var mic: AVCaptureDevice?
    var systemAudio: Bool
    var cameraShape: CameraShape = .circle
    var cameraOrientation: CameraOrientation = .auto
}

/// One recording from start to finished project folder.
@MainActor
final class RecordingSession {
    let folder: URL
    let options: RecordingOptions
    let pause = PauseClock()
    private var screen: ScreenSource?
    private var devices: DeviceRecorder?
    private var tracker: InputTracker?

    init(options: RecordingOptions) throws {
        self.options = options
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime])
            .replacingOccurrences(of: ":", with: ".")
        folder = ReelProject.libraryFolder.appendingPathComponent("Recording \(stamp).reel", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func prepare() throws {
        if options.camera != nil || options.mic != nil {
            let d = try DeviceRecorder(camera: options.camera, mic: options.mic,
                                       cameraURL: folder.appendingPathComponent("camera.mov"),
                                       micURL: folder.appendingPathComponent("mic.m4a"), orientation: options.cameraOrientation, pause: pause)
            d.warmUp()
            devices = d
        }
    }

    func start() async throws {
        let out = folder.appendingPathComponent("screen.mov")
        let recorder: ScreenSource
        switch options.source {
        case .display(let display):
            recorder = try ScreenRecorder(filter: try await Self.filterExcludingReel(display), pixelSize: Sources.evenPixels(display.frame),
                                          systemAudio: options.systemAudio, output: out, pause: pause)
        case .window(let window):
            recorder = try ScreenRecorder(filter: SCContentFilter(desktopIndependentWindow: window), pixelSize: Sources.evenPixels(window.frame),
                                          systemAudio: options.systemAudio, output: out, pause: pause)
        case .area(let display, let rect):
            let local = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            recorder = try ScreenRecorder(filter: try await Self.filterExcludingReel(display), pixelSize: Sources.evenPixels(rect),
                                          sourceRect: local, systemAudio: options.systemAudio, output: out, pause: pause)
        case .device(let device):
            recorder = try IOSScreenRecorder(device: device, output: out, pause: pause)
        }
        screen = recorder
        if let frame = options.source.frame {
            let t = InputTracker(area: frame, folder: folder)
            tracker = t
            t.start()
        }
        devices?.beginWriting()
        try await recorder.start()
    }

    /// Reel's own windows (the bar, the countdown, the editor) never appear in the video.
    private static func filterExcludingReel(_ display: SCDisplay) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mine = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        return SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
    }

    func pauseRecording() { pause.pause() }
    func resumeRecording() { pause.resume() }

    /// Stops everything and deletes the folder.
    func cancel() async {
        tracker?.stop()
        await screen?.cancel()
        await devices?.cancel()
        try? FileManager.default.removeItem(at: folder)
    }

    func stop() async throws -> ReelProject {
        let endHost = PauseClock.now
        if pause.isPaused { pause.resume(at: endHost) }
        let end = CMTime(seconds: pause.toRecording(endHost), preferredTimescale: 1_000_000_000)
        tracker?.stop()
        guard let screen else { throw RecorderError.noSource }
        async let devicesDone: Void = devices?.stop() ?? ()
        try await screen.stop(endTime: end)
        await devicesDone

        let first = screen.firstFrameTime ?? end
        let start = first.seconds
        let duration = max(0.1, (screen.lastFrameTime ?? end).seconds - start)
        let events = tracker?.events(relativeTo: start, duration: duration, pause: pause) ?? RecordingEvents()

        var info = RecordingInfo()
        info.duration = duration
        if let frame = options.source.frame {
            info.sourcePointWidth = frame.width
            info.sourcePointHeight = frame.height
        } else {
            info.sourcePointWidth = screen.pixelSize.width / 3
            info.sourcePointHeight = screen.pixelSize.height / 3
        }
        info.hasSystemAudio = options.systemAudio
        if let cs = devices?.cameraStart {
            info.cameraFile = "camera.mov"
            info.cameraOffset = cs.seconds - start
        }
        if let ms = devices?.micStart {
            info.micFile = "mic.m4a"
            info.micOffset = ms.seconds - start
        }

        var settings = EditSettings()
        settings.zooms = ZoomPlanner.autoZooms(clicks: events.clicks, duration: duration)
        settings.showCamera = info.cameraFile != nil
        settings.cameraShape = options.cameraShape
        switch options.source {
        case .display: break
        case .window, .area: settings.aspect = .auto
        case .device:
            settings.aspect = .auto
            settings.showCursor = false
        }

        let doc = ProjectDocument(name: folder.deletingPathExtension().lastPathComponent, recording: info, settings: settings)
        try ReelProject.write(events, to: folder.appendingPathComponent("events.json"))
        try ReelProject.write(doc, to: folder.appendingPathComponent("project.json"))
        return ReelProject(folder: folder, document: doc, events: events)
    }
}

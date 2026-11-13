import SwiftUI
import AVFoundation
import ScreenCaptureKit
import Carbon.HIToolbox

enum CaptureMode: String, CaseIterable, Identifiable {
    case display, window, area, device
    var id: String { rawValue }
    var label: String {
        switch self {
        case .display: return "Display"
        case .window: return "Window"
        case .area: return "Area"
        case .device: return "Device"
        }
    }
    var symbol: String {
        switch self {
        case .display: return "display"
        case .window: return "macwindow"
        case .area: return "rectangle.dashed"
        case .device: return "iphone"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case picking            // choosing a window or dragging an area
        case countdown(Int)
        case recording
        case paused
        case finishing
    }

    @Published var phase: Phase = .idle
    @Published var displays: [SCDisplay] = []
    @Published var windows: [SCWindow] = []
    @Published var cameras: [AVCaptureDevice] = []
    @Published var mics: [AVCaptureDevice] = []
    @Published var iosDevices: [AVCaptureDevice] = []
    @Published var projects: [ReelProject] = []
    @Published var error: String?
    @Published var permissionMissing = false

    // Choices, remembered between launches.
    @Published var mode: CaptureMode { didSet { defaults.set(mode.rawValue, forKey: "mode") } }
    @Published var cameraID: String? { didSet { defaults.set(cameraID ?? "", forKey: "cameraID") } }
    @Published var micID: String? { didSet { defaults.set(micID ?? "", forKey: "micID") } }
    @Published var deviceID: String? { didSet { defaults.set(deviceID, forKey: "deviceID") } }
    @Published var systemAudio: Bool { didSet { defaults.set(systemAudio, forKey: "systemAudio") } }
    @Published var countdownEnabled: Bool { didSet { defaults.set(countdownEnabled, forKey: "countdown") } }
    @Published var cameraShape: CameraShape { didSet { defaults.set(cameraShape.rawValue, forKey: "cameraShape") } }
    @Published var cameraOrientation: CameraOrientation { didSet { defaults.set(cameraOrientation.rawValue, forKey: "cameraOrientation") } }

    private let defaults = UserDefaults.standard
    private var session: RecordingSession?
    private var lastSource: CaptureSource?
    private var recordedBefore: TimeInterval = 0
    private var segmentStart: Date?
    private var hotKey: HotKey?
    private var observers: [NSObjectProtocol] = []

    init() {
        let d = UserDefaults.standard
        mode = CaptureMode(rawValue: d.string(forKey: "mode") ?? "") ?? .display
        // An empty string means the person turned it off; a missing key means first launch.
        cameraID = d.string(forKey: "cameraID").flatMap { $0.isEmpty ? nil : $0 } ?? (d.object(forKey: "cameraID") == nil ? AVCaptureDevice.default(for: .video)?.uniqueID : nil)
        micID = d.string(forKey: "micID").flatMap { $0.isEmpty ? nil : $0 } ?? (d.object(forKey: "micID") == nil ? AVCaptureDevice.default(for: .audio)?.uniqueID : nil)
        deviceID = d.string(forKey: "deviceID")
        systemAudio = d.object(forKey: "systemAudio") as? Bool ?? true
        countdownEnabled = d.object(forKey: "countdown") as? Bool ?? true
        cameraShape = CameraShape(rawValue: d.string(forKey: "cameraShape") ?? "") ?? .circle
        cameraOrientation = CameraOrientation(rawValue: d.string(forKey: "cameraOrientation") ?? "") ?? .auto

        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            Task { @MainActor in self?.toggleRecording() }
        }
        IOSDevices.enable()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.loadDevices() }
            })
        }
        refreshProjects()
        loadDevices()
    }

    var isRecording: Bool { phase == .recording || phase == .paused }

    var selectedCamera: AVCaptureDevice? { cameras.first { $0.uniqueID == cameraID } }
    var selectedMic: AVCaptureDevice? { mics.first { $0.uniqueID == micID } }
    var selectedDevice: AVCaptureDevice? { iosDevices.first { $0.uniqueID == deviceID } ?? iosDevices.first }

    /// Seconds recorded so far, not counting pauses.
    var elapsed: TimeInterval { recordedBefore + (segmentStart.map { Date().timeIntervalSince($0) } ?? 0) }

    func refreshProjects() {
        projects = ReelProject.listAll()
    }

    func loadSources() async {
        do {
            let s = try await Sources.load()
            displays = s.displays
            windows = s.windows
            permissionMissing = false
        } catch {
            permissionMissing = true
        }
        loadDevices()
    }

    func loadDevices() {
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                   mediaType: .video, position: .unspecified).devices
        mics = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                mediaType: .audio, position: .unspecified).devices
        iosDevices = IOSDevices.list()
    }

    func toggleRecording() {
        switch phase {
        case .idle: Task { await record() }
        case .countdown: cancelCountdown()
        case .recording, .paused: Task { await stop() }
        case .picking, .finishing: break
        }
    }

    // MARK: start

    func record() async {
        guard phase == .idle else { return }
        error = nil
        await loadSources()
        if permissionMissing && mode != .device {
            error = "Reel needs Screen Recording permission. Turn it on in System Settings > Privacy & Security > Screen Recording."
            return
        }
        let windowsUI: WindowManager = WindowManager.shared
        let source: CaptureSource
        switch mode {
        case .display:
            guard let d = windowsUI.displayUnderBar(displays) ?? displays.first else { error = RecorderError.noSource.localizedDescription; return }
            source = .display(d)
        case .window:
            phase = .picking
            guard let w = await windowsUI.pickWindow(windows) else { phase = .idle; return }
            source = .window(w)
        case .area:
            phase = .picking
            guard let (displayID, rect) = await windowsUI.pickArea(),
                  let d = displays.first(where: { $0.displayID == displayID }) else { phase = .idle; return }
            source = .area(d, rect)
        case .device:
            guard let device = selectedDevice else {
                error = "Connect an iPhone or iPad with a cable, unlock it and tap Trust if it asks."
                return
            }
            source = .device(device)
        }
        await begin(source)
    }

    func begin(_ source: CaptureSource) async {
        phase = .countdown(3)
        var needsVideo = selectedCamera != nil
        if case .device = source { needsVideo = true }
        if needsVideo, !(await AVCaptureDevice.requestAccess(for: .video)) {
            fail("Camera access is off. Turn it on in System Settings > Privacy & Security > Camera.")
            return
        }
        if selectedMic != nil, !(await AVCaptureDevice.requestAccess(for: .audio)) {
            fail("Microphone access is off. Turn it on in System Settings > Privacy & Security > Microphone.")
            return
        }
        var isDevice = false
        if case .device = source { isDevice = true }
        let options = RecordingOptions(source: source, camera: selectedCamera, mic: selectedMic,
                                       systemAudio: systemAudio && !isDevice, cameraShape: cameraShape, cameraOrientation: cameraOrientation)
        do {
            let s = try RecordingSession(options: options)
            try s.prepare()
            session = s
            lastSource = source
            if countdownEnabled {
                WindowManager.shared.showCountdown(over: source.frame)
                for n in stride(from: 3, through: 1, by: -1) {
                    phase = .countdown(n)
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    if phase != .countdown(n) {
                        WindowManager.shared.hideCountdown()
                        await s.cancel()
                        session = nil
                        return
                    }
                }
                WindowManager.shared.hideCountdown()
            }
            try await s.start()
            recordedBefore = 0
            segmentStart = Date()
            phase = .recording
            if case .area(_, let rect) = source { WindowManager.shared.showAreaOutline(rect) }
            Log.record.info("Recording started: \(source.id, privacy: .public)")
        } catch {
            WindowManager.shared.hideCountdown()
            if let s = session { await s.cancel() }
            session = nil
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        phase = .idle
        error = message
        Log.record.error("\(message, privacy: .public)")
    }

    func cancelCountdown() {
        if case .countdown = phase { phase = .idle }
    }

    // MARK: while recording

    func pause() {
        guard phase == .recording, let s = session else { return }
        s.pauseRecording()
        recordedBefore = elapsed
        segmentStart = nil
        phase = .paused
    }

    func resume() {
        guard phase == .paused, let s = session else { return }
        s.resumeRecording()
        segmentStart = Date()
        phase = .recording
    }

    func stop() async {
        guard isRecording, let s = session else { return }
        phase = .finishing
        WindowManager.shared.hideAreaOutline()
        do {
            let project = try await s.stop()
            session = nil
            phase = .idle
            refreshProjects()
            WindowManager.shared.openEditor(project.folder)
        } catch {
            session = nil
            fail(error.localizedDescription)
        }
    }

    /// Throws the recording away and returns to the ready bar.
    func discard() async {
        guard isRecording, let s = session else { return }
        phase = .finishing
        WindowManager.shared.hideAreaOutline()
        await s.cancel()
        session = nil
        phase = .idle
    }

    /// Throws the recording away and starts again on the same screen, window or area.
    func restart() async {
        guard let source = lastSource else { return }
        await discard()
        await begin(source)
    }

    func delete(_ project: ReelProject) {
        try? FileManager.default.trashItem(at: project.folder, resultingItemURL: nil)
        refreshProjects()
    }

    func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = ReelProject.libraryFolder
        panel.prompt = "Save here"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            defaults.set(url.path, forKey: "saveFolder")
            refreshProjects()
        }
    }
}

/// System-wide shortcut through Carbon, which needs no Accessibility permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private static var registry: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        let id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.registry[id] = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            HotKey.registry[hk.id]?.action()
            return noErr
        }, 1, &spec, nil, &handler)
        RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x5245454C), id: id),
                            GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

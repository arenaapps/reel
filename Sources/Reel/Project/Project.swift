import Foundation
import CoreGraphics

/// Raw input captured while recording. Times are seconds from the first screen frame.
/// Positions are normalised to the captured area, origin top-left, 0...1.
struct CursorSample: Codable, Equatable {
    var t: Double
    var x: Double
    var y: Double
    var cursor: Int?   // index into RecordingEvents.cursors, nil = unchanged
}

struct ClickEvent: Codable, Equatable {
    enum Button: String, Codable { case left, right, other }
    var t: Double
    var x: Double
    var y: Double
    var button: Button
}

struct CursorImage: Codable, Equatable {
    var file: String        // png inside the project folder
    var hotspotX: Double    // points, from top-left
    var hotspotY: Double
    var width: Double       // points
    var height: Double
}

struct RecordingEvents: Codable {
    var samples: [CursorSample] = []
    var clicks: [ClickEvent] = []
    var cursors: [CursorImage] = []
}

/// What was recorded and where the files are.
struct RecordingInfo: Codable {
    var screenFile = "screen.mov"
    var cameraFile: String?
    var micFile: String?
    /// Offset in seconds of the camera/mic files relative to the screen file.
    /// Positive means the file started after the first screen frame.
    var cameraOffset: Double = 0
    var micOffset: Double = 0
    var duration: Double = 0
    /// Captured area size in points (used to scale the cursor correctly).
    var sourcePointWidth: Double = 1920
    var sourcePointHeight: Double = 1080
    var hasSystemAudio = false
    var createdAt = Date()
}

struct RGBA: Codable, Equatable, Hashable {
    var r: Double, g: Double, b: Double, a: Double = 1
    static let white = RGBA(r: 1, g: 1, b: 1)
    static let black = RGBA(r: 0, g: 0, b: 0)
}

enum BackgroundStyle: Codable, Equatable {
    case gradient(RGBA, RGBA, angle: Double)
    case solid(RGBA)
    case image(String)   // absolute path to an image file
}

enum AspectPreset: String, Codable, CaseIterable, Identifiable {
    case auto, wide16x9, vertical9x16, square, classic4x3
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .wide16x9: return "16:9"
        case .vertical9x16: return "9:16"
        case .square: return "1:1"
        case .classic4x3: return "4:3"
        }
    }
    func ratio(source: CGSize) -> CGFloat {
        switch self {
        case .auto: return source.width / max(source.height, 1)
        case .wide16x9: return 16.0 / 9.0
        case .vertical9x16: return 9.0 / 16.0
        case .square: return 1
        case .classic4x3: return 4.0 / 3.0
        }
    }
}

enum CameraCorner: String, Codable, CaseIterable, Identifiable {
    case bottomLeft, bottomRight, topLeft, topRight
    var id: String { rawValue }
}

enum CameraShape: String, Codable, CaseIterable, Identifiable {
    case circle, rounded
    var id: String { rawValue }
}

/// A span of the timeline where the view zooms in.
struct ZoomSegment: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var scale: Double = 2.0
    /// nil = follow the cursor; otherwise a fixed normalised focus point.
    var focusX: Double?
    var focusY: Double?
    var isAuto = true
}

struct EditSettings: Codable, Equatable {
    var background: BackgroundStyle = .gradient(RGBA(r: 0.40, g: 0.33, b: 0.95), RGBA(r: 0.95, g: 0.45, b: 0.62), angle: 135)
    var aspect: AspectPreset = .wide16x9
    var padding: Double = 0.08          // fraction of the canvas' shorter side
    var cornerRadius: Double = 14       // in output points at 1080p
    var shadow: Double = 0.6            // 0...1
    var cursorScale: Double = 1.6
    var cursorSmoothing: Double = 0.6   // 0 = raw, 1 = very smooth
    var showCursor = true
    var clickEffect = true
    var zoomSpeed: Double = 0.5         // 0 slow ... 1 snappy
    var zooms: [ZoomSegment] = []
    var trimStart: Double = 0
    var trimEnd: Double?                // nil = end of recording
    var showCamera = true
    var cameraCorner: CameraCorner = .bottomLeft
    var cameraShape: CameraShape = .circle
    var cameraSize: Double = 0.22       // fraction of canvas height
    var micVolume: Double = 1
    var systemVolume: Double = 0.8
    var hideIdleCursor = true           // fade the cursor out when it sits still
    var motionBlur: Double = 0.5        // 0 = off, 1 = strong, applied while the camera moves

    init() {}

    /// Tolerates project files written before a setting existed: missing keys keep their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EditSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) throws -> T { try c.decodeIfPresent(T.self, forKey: k) ?? fallback }
        background = try v(.background, d.background)
        aspect = try v(.aspect, d.aspect)
        padding = try v(.padding, d.padding)
        cornerRadius = try v(.cornerRadius, d.cornerRadius)
        shadow = try v(.shadow, d.shadow)
        cursorScale = try v(.cursorScale, d.cursorScale)
        cursorSmoothing = try v(.cursorSmoothing, d.cursorSmoothing)
        showCursor = try v(.showCursor, d.showCursor)
        clickEffect = try v(.clickEffect, d.clickEffect)
        zoomSpeed = try v(.zoomSpeed, d.zoomSpeed)
        zooms = try v(.zooms, d.zooms)
        trimStart = try v(.trimStart, d.trimStart)
        trimEnd = try c.decodeIfPresent(Double.self, forKey: .trimEnd)
        showCamera = try v(.showCamera, d.showCamera)
        cameraCorner = try v(.cameraCorner, d.cameraCorner)
        cameraShape = try v(.cameraShape, d.cameraShape)
        cameraSize = try v(.cameraSize, d.cameraSize)
        micVolume = try v(.micVolume, d.micVolume)
        systemVolume = try v(.systemVolume, d.systemVolume)
        hideIdleCursor = try v(.hideIdleCursor, d.hideIdleCursor)
        motionBlur = try v(.motionBlur, d.motionBlur)
    }
}

struct ProjectDocument: Codable {
    var version = 1
    var name: String
    var recording: RecordingInfo
    var settings: EditSettings
}

/// A project on disk: a folder ending in .reel containing project.json, events.json and media.
final class ReelProject: ObservableObject, Identifiable {
    let folder: URL
    var id: URL { folder }
    @Published var document: ProjectDocument
    let events: RecordingEvents

    init(folder: URL, document: ProjectDocument, events: RecordingEvents) {
        self.folder = folder
        self.document = document
        self.events = events
    }

    var screenURL: URL { folder.appendingPathComponent(document.recording.screenFile) }
    var cameraURL: URL? { document.recording.cameraFile.map { folder.appendingPathComponent($0) } }
    var micURL: URL? { document.recording.micFile.map { folder.appendingPathComponent($0) } }

    static func load(_ folder: URL) throws -> ReelProject {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let doc = try dec.decode(ProjectDocument.self, from: Data(contentsOf: folder.appendingPathComponent("project.json")))
        let evURL = folder.appendingPathComponent("events.json")
        let ev = (try? dec.decode(RecordingEvents.self, from: Data(contentsOf: evURL))) ?? RecordingEvents()
        return ReelProject(folder: folder, document: doc, events: ev)
    }

    func save() throws {
        try Self.write(document, to: folder.appendingPathComponent("project.json"))
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(value).write(to: url, options: .atomic)
    }

    static var defaultLibraryFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!.appendingPathComponent("Reel", isDirectory: true)
    }

    /// Where new recordings go. Changed from the gear menu; defaults to ~/Movies/Reel.
    static var libraryFolder: URL {
        let url = UserDefaults.standard.string(forKey: "saveFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultLibraryFolder
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func listAll() -> [ReelProject] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: libraryFolder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "reel" }
            .compactMap { try? load($0) }
            .sorted { $0.document.recording.createdAt > $1.document.recording.createdAt }
    }
}

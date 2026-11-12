import XCTest
import AVFoundation
@testable import Reel

/// Runs the real composition and export on a fixture folder.
/// Set REEL_FIXTURE to a folder holding screen.mov, events.json and optionally camera.mov / mic.m4a.
final class RenderPipelineTests: XCTestCase {
    func testExportsFixture() async throws {
        guard let path = ProcessInfo.processInfo.environment["REEL_FIXTURE"] else { throw XCTSkip("REEL_FIXTURE not set") }
        let folder = URL(fileURLWithPath: path)
        var info = RecordingInfo()
        info.duration = 6
        info.sourcePointWidth = 1440
        info.sourcePointHeight = 900
        info.cameraFile = "camera.mov"
        info.micFile = "mic.m4a"
        let events = try JSONDecoder().decode(RecordingEvents.self, from: Data(contentsOf: folder.appendingPathComponent("events.json")))
        var settings = EditSettings()
        settings.zooms = ZoomPlanner.autoZooms(clicks: events.clicks, duration: 6)
        let doc = ProjectDocument(name: "fixture", recording: info, settings: settings)
        try ReelProject.write(doc, to: folder.appendingPathComponent("project.json"))
        let project = try ReelProject.load(folder)

        // Still frames at a few moments.
        let built = try await CompositionBuilder.build(project: project, settings: settings, renderSize: CGSize(width: 1920, height: 1080), fps: 30)
        let gen = AVAssetImageGenerator(asset: built.composition)
        gen.videoComposition = built.videoComposition
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        for t in [0.5, 0.65, 0.75, 0.9, 2.0, 3.8, 4.8] {
            let (cg, _) = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600))
            let rep = NSBitmapImageRep(cgImage: cg)
            try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("frame-\(t).png"))
        }

        let out = folder.appendingPathComponent("export.mp4")
        try await Exporter.export(project: project, options: ExportOptions(format: .mp4, quality: .p1080, fps: 30), to: out) { _ in }
        let asset = AVURLAsset(url: out)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 6, accuracy: 0.2)
        let v = try await asset.loadTracks(withMediaType: .video).first!
        let size = try await v.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1920, height: 1080))
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(audio.isEmpty)

        let gif = folder.appendingPathComponent("export.gif")
        try await Exporter.export(project: project, options: ExportOptions(format: .gif, gifWidth: 640, gifFPS: 10), to: gif) { _ in }
        XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: gif.path)[.size] as! Int, 10_000)
    }
}

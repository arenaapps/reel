import XCTest
@testable import Reel

final class MotionTests: XCTestCase {
    func testAutoZoomsMergeClickBursts() {
        let clicks = [1.0, 1.5, 2.2, 9.0].map { ClickEvent(t: $0, x: 0.5, y: 0.5, button: .left) }
        let z = ZoomPlanner.autoZooms(clicks: clicks, duration: 20)
        XCTAssertEqual(z.count, 2)
        XCTAssertEqual(z[0].start, 0.4, accuracy: 1e-9)
        XCTAssertEqual(z[0].end, 4.6, accuracy: 1e-9)
        XCTAssertEqual(z[1].start, 8.4, accuracy: 1e-9)
    }

    func testSmoothedCursorConvergesToTarget() {
        let samples = [CursorSample(t: 0, x: 0, y: 0, cursor: nil), CursorSample(t: 0.1, x: 1, y: 1, cursor: nil)]
        let track = Motion.smoothedCursor(samples, duration: 3, smoothing: 0.8)
        let mid = track.value(at: 0.15)!
        XCTAssertLessThan(mid.x, 0.9)          // lags behind the raw jump
        let end = track.value(at: 3)!
        XCTAssertEqual(end.x, 1, accuracy: 0.01)
    }

    func testCameraZoomsInDuringSegmentAndBackOut() {
        let cursor = SampledTrack(rate: Motion.rate, values: Array(repeating: Vec2(x: 0.2, y: 0.3), count: 1201))
        let zooms = [ZoomSegment(start: 2, end: 6, scale: 2)]
        let cam = ZoomPlanner.cameraTrack(zooms: zooms, cursor: cursor, duration: 10, speed: 0.5)
        XCTAssertEqual(cam.value(at: 1)!.scale, 1, accuracy: 1e-6)
        XCTAssertEqual(cam.value(at: 5)!.scale, 2, accuracy: 0.05)
        XCTAssertEqual(cam.value(at: 5)!.focus.x, 0.2, accuracy: 0.01)
        XCTAssertLessThan(cam.value(at: 9.5)!.scale, 1.05)
    }

    func testRenderSizes() {
        let s = RenderSizing.size(aspect: .wide16x9, source: CGSize(width: 2880, height: 1800), shortSide: 1080)
        XCTAssertEqual(s, CGSize(width: 1920, height: 1080))
        let v = RenderSizing.size(aspect: .vertical9x16, source: .zero, shortSide: 1080)
        XCTAssertEqual(v, CGSize(width: 1080, height: 1920))
    }

    func testIdleCursorFadesOutAndBackIn() {
        // Moves for a second, sits still until 5 s, then moves again.
        var samples: [CursorSample] = []
        for i in 0...10 { samples.append(CursorSample(t: Double(i) * 0.1, x: Double(i) * 0.05, y: 0.5, cursor: nil)) }
        samples.append(CursorSample(t: 5.0, x: 0.5, y: 0.5, cursor: nil))
        samples.append(CursorSample(t: 5.05, x: 0.6, y: 0.5, cursor: nil))
        let a = Motion.idleOpacity(samples, clicks: [], duration: 8)
        XCTAssertEqual(a.value(at: 1.5)!, 1, accuracy: 1e-9)    // still within the idle delay
        XCTAssertEqual(a.value(at: 4.0)!, 0, accuracy: 1e-9)    // faded out
        XCTAssertEqual(a.value(at: 5.4)!, 1, accuracy: 1e-9)    // back after moving
    }

    func testClickKeepsCursorVisible() {
        let samples = [CursorSample(t: 0, x: 0.5, y: 0.5, cursor: nil)]
        let a = Motion.idleOpacity(samples, clicks: [ClickEvent(t: 3, x: 0.5, y: 0.5, button: .left)], duration: 6)
        XCTAssertEqual(a.value(at: 3.5)!, 1, accuracy: 1e-9)
    }

    func testOldProjectSettingsStillDecode() throws {
        // A project.json written before hideIdleCursor and motionBlur existed.
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(EditSettings())) as! [String: Any]
        old.removeValue(forKey: "hideIdleCursor")
        old.removeValue(forKey: "motionBlur")
        old["padding"] = 0.2
        let decoded = try JSONDecoder().decode(EditSettings.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(decoded.padding, 0.2)
        XCTAssertTrue(decoded.hideIdleCursor)
        XCTAssertEqual(decoded.motionBlur, 0.5)
    }

    func testPauseClockRemovesPausedTime() {
        let c = PauseClock()
        c.pause(at: 10); c.resume(at: 13)
        c.pause(at: 20); c.resume(at: 21)
        XCTAssertEqual(c.toRecording(5), 5)
        XCTAssertEqual(c.toRecording(11), 10)      // inside the first pause maps to its start
        XCTAssertTrue(c.isInPause(12))
        XCTAssertFalse(c.isInPause(13))
        XCTAssertEqual(c.toRecording(15), 12)
        XCTAssertEqual(c.toRecording(25), 21)
        c.pause(at: 30)
        XCTAssertTrue(c.isPaused)
        XCTAssertEqual(c.toRecording(40), 26)
    }
}

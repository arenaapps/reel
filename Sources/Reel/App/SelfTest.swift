import AppKit
import AVFoundation

/// `Reel --selftest /path/out.txt` records a short clip in each Mac mode (display, area,
/// front window) with a pause in the middle, checks the files, writes a report and quits.
/// Development only.
extension AppModel {
    func selfTest(report: URL) async {
        var lines: [String] = []
        // Leave the person's own choices as they were once the test is done.
        let saved = (countdownEnabled, cameraID, micID, mode)
        defer { (countdownEnabled, cameraID, micID, mode) = saved }
        countdownEnabled = false
        cameraID = nil
        micID = nil
        await loadSources()
        guard let display = displays.first else {
            try? "FAIL no displays (permission: \(permissionMissing))".write(to: report, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
            return
        }
        let area = CGRect(x: display.frame.minX + 100, y: display.frame.minY + 120, width: 640, height: 400)
        var cases: [(String, CaptureSource)] = [("display", .display(display)), ("area", .area(display, area))]
        if let w = windows.first { cases.append(("window", .window(w))) }
        for (name, source) in cases {
            await begin(source)
            guard phase == .recording else { lines.append("FAIL \(name): did not start, \(error ?? "")"); continue }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            pause()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            resume()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let before = projects.count
            await stop()
            refreshProjects()
            guard projects.count > before, let p = projects.first else { lines.append("FAIL \(name): no project, \(error ?? "")"); continue }
            let asset = AVURLAsset(url: p.screenURL)
            let d = (try? await asset.load(.duration).seconds) ?? 0
            let size = (try? await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)) ?? .zero
            let ok = abs(d - 3.0) < 0.6
            lines.append("\(ok ? "PASS" : "FAIL") \(name): file \(String(format: "%.2f", d)) s (expect ~3.0 with 1.5 s paused), project \(String(format: "%.2f", p.document.recording.duration)) s, \(Int(size.width))x\(Int(size.height)), \(p.events.samples.count) cursor samples, folder \(p.folder.lastPathComponent)")
        }
        try? lines.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8)
        (countdownEnabled, cameraID, micID, mode) = saved
        NSApp.terminate(nil)
    }
}

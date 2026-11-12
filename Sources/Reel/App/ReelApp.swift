import SwiftUI

@main
struct ReelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            MenuLabel(model: delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        WindowManager.shared = WindowManager(model: model)
        // Development: `Reel --open /path/to/project.reel` opens the editor straight away.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count {
            WindowManager.shared.openEditor(URL(fileURLWithPath: args[i + 1]))
        }
        WindowManager.shared.showBar()
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
            let report = URL(fileURLWithPath: args[i + 1])
            Task { await model.selfTest(report: report) }
        }
    }

    /// Clicking the Dock icon brings the bar back if it was hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowManager.shared.showBar()
        return true
    }
}

struct MenuLabel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        switch model.phase {
        case .recording: Image(systemName: "record.circle.fill")
        case .paused: Image(systemName: "pause.circle")
        case .countdown(let n): Text("\(n)")
        default: Image(systemName: "record.circle")
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    var body: some View {
        switch model.phase {
        case .recording, .paused:
            Button("Stop recording  ⌘⇧2") { model.toggleRecording() }
        case .countdown:
            Button("Cancel") { model.cancelCountdown() }
        case .finishing:
            Text("Saving…")
        case .idle, .picking:
            Button("Start recording  ⌘⇧2") { model.toggleRecording() }
        }
        Divider()
        Button("Show recording bar") { WindowManager.shared.showBar() }
        Button("Recordings") { WindowManager.shared.showLibrary() }
        Divider()
        Button("Quit Reel") { NSApp.terminate(nil) }
    }
}

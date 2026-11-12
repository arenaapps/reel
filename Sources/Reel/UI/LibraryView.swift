import SwiftUI
import AVFoundation

/// The recordings library, opened from the folder button on the bar.
struct LibraryView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recordings").font(.title2.bold())
                Spacer()
                Button {
                    NSWorkspace.shared.open(ReelProject.libraryFolder)
                } label: { Image(systemName: "folder") }
                .help("Show recordings in Finder")
            }
            .padding(20)
            if model.projects.isEmpty {
                Spacer()
                Text("Your recordings will appear here.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                        ForEach(model.projects) { p in
                            ProjectCard(project: p)
                                .onTapGesture(count: 2) { WindowManager.shared.openEditor(p.folder) }
                                .contextMenu {
                                    Button("Open") { WindowManager.shared.openEditor(p.folder) }
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([p.folder]) }
                                    Divider()
                                    Button("Move to Trash", role: .destructive) { model.delete(p) }
                                }
                        }
                    }
                    .padding([.horizontal, .bottom], 20)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}

struct ProjectCard: View {
    let project: ReelProject
    @State private var thumb: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(.quaternary)
                if let thumb { Image(nsImage: thumb).resizable().scaledToFill() }
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(project.document.name).font(.callout).lineLimit(1)
            Text(Self.duration(project.document.recording.duration)).font(.caption).foregroundStyle(.secondary)
        }
        .task {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: project.screenURL))
            gen.maximumSize = CGSize(width: 480, height: 480)
            if let (cg, _) = try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) {
                thumb = NSImage(cgImage: cg, size: .zero)
            }
        }
    }

    static func duration(_ s: Double) -> String {
        let total = Int(s.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

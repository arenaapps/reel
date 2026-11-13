import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case mp4, gif
    var id: String { rawValue }
    var label: String { self == .mp4 ? "MP4 video" : "GIF" }
}

enum ExportQuality: Int, CaseIterable, Identifiable {
    case p720 = 720, p1080 = 1080, p1440 = 1440, p2160 = 2160
    var id: Int { rawValue }
    var label: String { self == .p2160 ? "4K" : "\(rawValue)p" }
}

struct ExportOptions {
    var format: ExportFormat = .mp4
    var quality: ExportQuality = .p1080
    var fps: Int32 = 60
    var gifWidth: CGFloat = 960
    var gifFPS: Double = 15
}

enum Exporter {
    static func export(project: ReelProject, options: ExportOptions, to url: URL,
                       progress: @escaping (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        let source = try await CompositionBuilder.sourceSize(of: project)
        let settings = project.document.settings
        switch options.format {
        case .mp4:
            let size = RenderSizing.size(aspect: settings.aspect, source: source, shortSide: CGFloat(options.quality.rawValue))
            let built = try await CompositionBuilder.build(project: project, settings: settings, renderSize: size, fps: options.fps)
            guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHighestQuality) else {
                throw ExportError.cannotStart
            }
            session.videoComposition = built.videoComposition
            session.audioMix = built.audioMix
            session.audioTimePitchAlgorithm = .spectral     // sped-up voice keeps its pitch
            session.outputURL = url
            session.outputFileType = .mp4
            session.shouldOptimizeForNetworkUse = true
            let poll = Task {
                while !Task.isCancelled {
                    progress(Double(session.progress))
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            await session.export()
            poll.cancel()
            if session.status != .completed { throw session.error ?? ExportError.cannotStart }
            progress(1)
        case .gif:
            let full = RenderSizing.size(aspect: settings.aspect, source: source, shortSide: 1080)
            let k = options.gifWidth / full.width
            let size = CGSize(width: (full.width * k / 2).rounded() * 2, height: (full.height * k / 2).rounded() * 2)
            let built = try await CompositionBuilder.build(project: project, settings: settings, renderSize: size, fps: 30)
            let gen = AVAssetImageGenerator(asset: built.composition)
            gen.videoComposition = built.videoComposition
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            gen.appliesPreferredTrackTransform = false
            let duration = built.state.outputDuration
            let count = max(1, Int(duration * options.gifFPS))
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil) else {
                throw ExportError.cannotStart
            }
            CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: 1 / options.gifFPS]] as CFDictionary
            for i in 0..<count {
                try Task.checkCancellation()
                let t = CMTime(seconds: Double(i) / options.gifFPS, preferredTimescale: 600)
                let (image, _) = try await gen.image(at: t)
                CGImageDestinationAddImage(dest, image, frameProps)
                progress(Double(i + 1) / Double(count))
            }
            guard CGImageDestinationFinalize(dest) else { throw ExportError.cannotStart }
        }
    }
}

enum ExportError: LocalizedError {
    case cannotStart
    var errorDescription: String? { "The export could not be finished." }
}

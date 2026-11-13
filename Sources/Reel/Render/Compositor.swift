import AVFoundation
import CoreImage

final class ReelInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let state: RenderState
    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID?

    init(timeRange: CMTimeRange, state: RenderState, screenTrackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID?) {
        self.timeRange = timeRange
        self.state = state
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        var ids = [NSNumber(value: screenTrackID)]
        if let cameraTrackID { ids.append(NSNumber(value: cameraTrackID)) }
        requiredSourceTrackIDs = ids
    }
}

/// Draws each frame of the preview and the export through RenderState.render.
final class ReelCompositor: NSObject, AVVideoCompositing {
    static let context = CIContext(options: [.cacheIntermediates: false, .priorityRequestLow: false])
    private let queue = DispatchQueue(label: "reel.compositor")
    private var cancelled = false

    var sourcePixelBufferAttributes: [String: Any]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: Any] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async {
            if self.cancelled { request.finishCancelledRequest(); return }
            guard let instruction = request.videoCompositionInstruction as? ReelInstruction,
                  let out = request.renderContext.newPixelBuffer() else {
                Log.render.error("compositor request missing instruction or buffer")
                request.finish(with: NSError(domain: "Reel", code: 1))
                return
            }
            let state = instruction.state
            let screen = request.sourceFrame(byTrackID: instruction.screenTrackID).map { CIImage(cvPixelBuffer: $0) }
            let camera = instruction.cameraTrackID.flatMap { request.sourceFrame(byTrackID: $0) }.map { CIImage(cvPixelBuffer: $0) }
            let t = state.mappedTimeline.source(at: request.compositionTime.seconds)
            let image = state.render(screen: screen, camera: camera, at: t)
            Self.context.render(image, to: out, bounds: CGRect(origin: .zero, size: state.renderSize),
                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            request.finish(withComposedVideoFrame: out)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        cancelled = true
        queue.async(flags: .barrier) { self.cancelled = false }
    }
}

/// Builds the AVFoundation composition for a project at a given output size.
enum CompositionBuilder {
    struct Built {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        let audioMix: AVMutableAudioMix
        let state: RenderState
    }

    static func sourceSize(of project: ReelProject) async throws -> CGSize {
        let asset = AVURLAsset(url: project.screenURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw RecorderError.noFrames }
        return try await track.load(.naturalSize)
    }

    static func build(project: ReelProject, settings: EditSettings, renderSize: CGSize, fps: Int32 = 60) async throws -> Built {
        let rec = project.document.recording
        let comp = AVMutableComposition()
        let screenAsset = AVURLAsset(url: project.screenURL)
        guard let screenTrack = try await screenAsset.loadTracks(withMediaType: .video).first else { throw RecorderError.noFrames }
        let sourceSize = try await screenTrack.load(.naturalSize)

        let state = RenderState(settings: settings, recording: rec, events: project.events, folder: project.folder,
                                renderSize: renderSize, sourceSize: sourceSize)
        let kept = state.mappedTimeline.kept
        let length = state.mappedTimeline.length
        let timescale: CMTimeScale = 600
        func cm(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: timescale) }

        /// Inserts the kept stretches of a file that starts `offset` seconds into the recording,
        /// back to back, so cuts and trimmed ends drop out of the video.
        /// Faster stretches are squeezed with scaleTimeRange. Sound above 2x is left out: too fast to follow.
        func insert(_ track: AVAssetTrack, fileDuration: Double, offset: Double, into dst: AVMutableCompositionTrack,
                    isAudio: Bool = false) throws {
            var at = 0.0
            for r in kept {
                defer { at += r.played }
                if isAudio && r.speed > 2.001 { continue }
                let fs = max(0, r.start - offset)
                let fe = min(fileDuration, r.end - offset)
                let lead = max(0, offset - r.start) / r.speed
                guard fe - fs > 0.01 else { continue }
                let pos = cm(at + lead)
                try dst.insertTimeRange(CMTimeRange(start: cm(fs), duration: cm(fe - fs)), of: track, at: pos)
                if abs(r.speed - 1) > 1e-6 {
                    dst.scaleTimeRange(CMTimeRange(start: pos, duration: cm(fe - fs)), toDuration: cm((fe - fs) / r.speed))
                }
            }
        }

        let screenDuration = try await screenAsset.load(.duration).seconds
        let vScreen = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try insert(screenTrack, fileDuration: screenDuration, offset: 0, into: vScreen)

        var params: [AVMutableAudioMixInputParameters] = []
        if rec.hasSystemAudio, let audio = try await screenAsset.loadTracks(withMediaType: .audio).first {
            let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try insert(audio, fileDuration: screenDuration, offset: 0, into: t, isAudio: true)
            let p = AVMutableAudioMixInputParameters(track: t)
            p.setVolume(Float(settings.systemVolume), at: .zero)
            params.append(p)
        }

        var cameraID: CMPersistentTrackID?
        if let url = project.cameraURL, FileManager.default.fileExists(atPath: url.path) {
            let asset = AVURLAsset(url: url)
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
                try insert(track, fileDuration: try await asset.load(.duration).seconds, offset: rec.cameraOffset, into: t)
                cameraID = t.trackID
            }
        }
        if let url = project.micURL, FileManager.default.fileExists(atPath: url.path) {
            let asset = AVURLAsset(url: url)
            if let track = try await asset.loadTracks(withMediaType: .audio).first {
                let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
                try insert(track, fileDuration: try await asset.load(.duration).seconds, offset: rec.micOffset, into: t, isAudio: true)
                let p = AVMutableAudioMixInputParameters(track: t)
                p.setVolume(Float(settings.micVolume), at: .zero)
                params.append(p)
            }
        }

        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = ReelCompositor.self
        vc.frameDuration = CMTime(value: 1, timescale: fps)
        vc.renderSize = renderSize
        vc.instructions = [ReelInstruction(timeRange: CMTimeRange(start: .zero, duration: cm(length)), state: state,
                                           screenTrackID: vScreen.trackID, cameraTrackID: cameraID)]
        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        return Built(composition: comp, videoComposition: vc, audioMix: mix, state: state)
    }
}

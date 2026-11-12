import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// Writes the screen (without the cursor) and optional system audio to a .mov.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, ScreenSource {
    private let stream: SCStream
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "reel.screen")
    private var sessionStarted = false
    private var lastVideo: CMSampleBuffer?
    private(set) var firstFrameTime: CMTime?   // host clock
    private(set) var lastFrameTime: CMTime?   // pauses removed
    let pixelSize: CGSize
    private let pause: PauseClock
    var onError: ((Error) -> Void)?

    /// `sourceRect` limits capture to part of the display, in display points from its top-left.
    init(filter: SCContentFilter, pixelSize: CGSize, sourceRect: CGRect? = nil, systemAudio: Bool, output: URL, pause: PauseClock) throws {
        self.pixelSize = pixelSize
        self.pause = pause
        let config = SCStreamConfiguration()
        if let sourceRect { config.sourceRect = sourceRect }
        config.width = Int(pixelSize.width)
        config.height = Int(pixelSize.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 8
        config.capturesAudio = systemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2

        writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let pixels = Double(config.width * config.height)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(8_000_000, pixels * 8),
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoAllowFrameReorderingKey: false
            ]
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        videoInput = video

        if systemAudio {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ])
            audio.expectsMediaDataInRealTime = true
            writer.add(audio)
            audioInput = audio
        } else {
            audioInput = nil
        }

        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        super.init()
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if systemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
    }

    func start() async throws {
        guard writer.startWriting() else { throw writer.error ?? RecorderError.writerFailed }
        try await stream.startCapture()
    }

    /// Stops capture and closes the file. `endTime` is the host time Stop was pressed.
    func stop(endTime: CMTime) async throws {
        try? await stream.stopCapture()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                // ScreenCaptureKit sends no frames while the screen is still, so repeat the
                // last frame at the stop time to make the file as long as the recording.
                if let last = self.lastVideo, self.sessionStarted, endTime > (self.lastFrameTime ?? .zero) {
                    if let copy = last.stamped(at: endTime), self.videoInput.isReadyForMoreMediaData {
                        self.videoInput.append(copy)
                        self.lastFrameTime = endTime
                    }
                }
                self.lastVideo = nil
                c.resume()
            }
        }
        guard sessionStarted else {
            writer.cancelWriting()
            throw RecorderError.noFrames
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        // Without an explicit end the last frame inherits the gap before it (frames are sparse
        // when the screen is still), which makes the file longer than the recording.
        writer.endSession(atSourceTime: lastFrameTime ?? endTime)
        await writer.finishWriting()
        if writer.status == .failed { throw writer.error ?? RecorderError.writerFailed }
    }

    func cancel() async {
        try? await stream.stopCapture()
        writer.cancelWriting()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer raw: CMSampleBuffer, of type: SCStreamOutputType) {
        guard raw.isValid, writer.status == .writing else { return }
        // Drop what arrives while paused and close the gap afterwards.
        let host = raw.presentationTimeStamp.seconds
        if pause.isInPause(host) { return }
        guard let sb = raw.shifted(by: host - pause.toRecording(host)) else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(raw, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete else { return }
            let pts = sb.presentationTimeStamp
            if !sessionStarted {
                writer.startSession(atSourceTime: pts)
                sessionStarted = true
                firstFrameTime = pts
            }
            if videoInput.isReadyForMoreMediaData {
                videoInput.append(sb)
                lastVideo = sb
                lastFrameTime = pts
            }
        case .audio:
            guard sessionStarted, let audioInput, audioInput.isReadyForMoreMediaData,
                  sb.presentationTimeStamp >= (firstFrameTime ?? .zero) else { return }
            audioInput.append(sb)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }
}

enum RecorderError: LocalizedError {
    case writerFailed, noFrames, noSource, deviceUnavailable, noDeviceFrames
    var errorDescription: String? {
        switch self {
        case .deviceUnavailable: return "The iPhone or iPad could not be opened. Unplug it, plug it back in and unlock it."
        case .noDeviceFrames: return "Nothing arrived from the iPhone or iPad. Keep it unlocked while recording."
        case .writerFailed: return "The video file could not be written."
        case .noFrames: return "No screen frames arrived. Check Screen Recording permission in System Settings."
        case .noSource: return "Pick a screen or window to record."
        }
    }
}

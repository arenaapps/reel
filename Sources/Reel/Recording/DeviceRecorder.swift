import AVFoundation
import CoreMedia

/// Records the camera to camera.mov and the microphone to mic.m4a.
/// Sample times are converted to the host clock so they line up with the screen.
final class DeviceRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "reel.devices")
    private var cameraWriter: AVAssetWriter?
    private var cameraInput: AVAssetWriterInput?
    private var micWriter: AVAssetWriter?
    private var micInput: AVAssetWriterInput?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var recording = false
    private(set) var cameraStart: CMTime?
    private(set) var micStart: CMTime?

    let hasCamera: Bool
    let hasMic: Bool
    private let pause: PauseClock

    init(camera: AVCaptureDevice?, mic: AVCaptureDevice?, cameraURL: URL, micURL: URL, pause: PauseClock) throws {
        self.pause = pause
        hasCamera = camera != nil
        hasMic = mic != nil
        super.init()
        session.beginConfiguration()
        if let camera {
            let input = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(input) { session.addInput(input) }
            if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
            let out = AVCaptureVideoDataOutput()
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            out.alwaysDiscardsLateVideoFrames = true
            out.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(out) { session.addOutput(out) }
            videoOutput = out

            let w = try AVAssetWriter(outputURL: cameraURL, fileType: .mov)
            let i = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 1280,
                AVVideoHeightKey: 720,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000]
            ])
            i.expectsMediaDataInRealTime = true
            w.add(i)
            cameraWriter = w
            cameraInput = i
        }
        if let mic {
            let input = try AVCaptureDeviceInput(device: mic)
            if session.canAddInput(input) { session.addInput(input) }
            let out = AVCaptureAudioDataOutput()
            out.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(out) { session.addOutput(out) }
            audioOutput = out

            let w = try AVAssetWriter(outputURL: micURL, fileType: .m4a)
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000
            ])
            i.expectsMediaDataInRealTime = true
            w.add(i)
            micWriter = w
            micInput = i
        }
        session.commitConfiguration()
    }

    /// Starts the devices early so they are warm when the countdown ends.
    func warmUp() {
        guard hasCamera || hasMic else { return }
        queue.async { self.session.startRunning() }
    }

    func beginWriting() {
        queue.async {
            self.cameraWriter?.startWriting()
            self.micWriter?.startWriting()
            self.recording = true
        }
    }

    func stop() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { self.recording = false; c.resume() }
        }
        session.stopRunning()
        if let w = cameraWriter, w.status == .writing {
            if cameraStart != nil { cameraInput?.markAsFinished(); await w.finishWriting() } else { w.cancelWriting() }
        }
        if let w = micWriter, w.status == .writing {
            if micStart != nil { micInput?.markAsFinished(); await w.finishWriting() } else { w.cancelWriting() }
        }
    }

    private func hostTime(_ t: CMTime) -> CMTime {
        guard let clock = session.synchronizationClock else { return t }
        return CMSyncConvertTime(t, from: clock, to: CMClockGetHostTimeClock())
    }

    func cancel() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { self.recording = false; c.resume() }
        }
        session.stopRunning()
        cameraWriter?.cancelWriting()
        micWriter?.cancelWriting()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput raw: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard recording else { return }
        let host = hostTime(raw.presentationTimeStamp).seconds
        if pause.isInPause(host) { return }
        guard let sb = raw.shifted(by: host - pause.toRecording(host)) else { return }
        if output === videoOutput, let w = cameraWriter, let i = cameraInput, w.status == .writing {
            if cameraStart == nil {
                w.startSession(atSourceTime: sb.presentationTimeStamp)
                cameraStart = hostTime(sb.presentationTimeStamp)
            }
            if i.isReadyForMoreMediaData { i.append(sb) }
        } else if output === audioOutput, let w = micWriter, let i = micInput, w.status == .writing {
            if micStart == nil {
                w.startSession(atSourceTime: sb.presentationTimeStamp)
                micStart = hostTime(sb.presentationTimeStamp)
            }
            if i.isReadyForMoreMediaData { i.append(sb) }
        }
    }
}

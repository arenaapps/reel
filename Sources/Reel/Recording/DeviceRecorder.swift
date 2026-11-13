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
    private var cameraURL_: URL?
    private(set) var cameraStart: CMTime?
    private(set) var micStart: CMTime?

    let hasCamera: Bool
    let hasMic: Bool
    private let pause: PauseClock

    init(camera: AVCaptureDevice?, mic: AVCaptureDevice?, cameraURL: URL, micURL: URL, orientation: CameraOrientation = .auto, pause: PauseClock) throws {
        self.pause = pause
        hasCamera = camera != nil
        hasMic = mic != nil
        super.init()
        session.beginConfiguration()
        if let camera {
            let input = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(input) { session.addInput(input) }
            // Keep the camera's own format (an Osmo in portrait sends a tall picture);
            // a fixed preset would force or squash it into 16:9.
            // Setting the device's format directly takes it out of the session presets.
            if (try? camera.lockForConfiguration()) != nil {
                camera.activeFormat = Self.bestFormat(for: camera, orientation: orientation)
                camera.unlockForConfiguration()
            }
            let out = AVCaptureVideoDataOutput()
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            out.alwaysDiscardsLateVideoFrames = true
            out.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(out) { session.addOutput(out) }
            videoOutput = out
            cameraURL_ = cameraURL
            Log.record.info("camera \(camera.localizedName, privacy: .public) format \(String(describing: camera.activeFormat.formatDescription.dimensions), privacy: .public)")
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
        if output === videoOutput, cameraWriter == nil, let url = cameraURL_ {
            makeCameraWriter(for: sb, url: url)
        }
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

    /// Sized from the first frame so the file keeps the camera's real shape.
    /// The long side is capped at 1920 to keep files small.
    private func makeCameraWriter(for sb: CMSampleBuffer, url: URL) {
        guard let pb = sb.imageBuffer else { return }
        let w0 = CGFloat(CVPixelBufferGetWidth(pb)), h0 = CGFloat(CVPixelBufferGetHeight(pb))
        let k = min(1, 1920 / max(w0, h0))
        let width = Int((w0 * k / 2).rounded(.down) * 2), height = Int((h0 * k / 2).rounded(.down) * 2)
        do {
            let w = try AVAssetWriter(outputURL: url, fileType: .mov)
            let i = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(6_000_000, width * height * 4)]
            ])
            i.expectsMediaDataInRealTime = true
            w.add(i)
            guard w.startWriting() else {
                Log.record.error("camera writer failed: \(w.error?.localizedDescription ?? "unknown", privacy: .public)")
                return
            }
            cameraWriter = w
            cameraInput = i
            Log.record.info("camera file \(width)x\(height) from \(Int(w0))x\(Int(h0))")
        } catch {
            Log.record.error("camera writer failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The sharpest format the right way round, up to 1920 on the long side and at least 30 fps.
    /// `auto` keeps the shape of the camera's current format; landscape or portrait asks for
    /// that shape and falls back to the current shape if the camera does not offer it.
    static func bestFormat(for camera: AVCaptureDevice, orientation: CameraOrientation = .auto) -> AVCaptureDevice.Format {
        let cur = camera.activeFormat.formatDescription.dimensions
        let ratio = Double(max(cur.width, cur.height)) / Double(max(1, min(cur.width, cur.height)))
        func candidates(portrait: Bool, sameRatio: Bool) -> [AVCaptureDevice.Format] {
            camera.formats.filter { f in
                let d = f.formatDescription.dimensions
                let r = Double(max(d.width, d.height)) / Double(max(1, min(d.width, d.height)))
                return (d.height > d.width) == portrait && (!sameRatio || abs(r - ratio) < 0.02)
                    && max(d.width, d.height) <= 1920
                    && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 29 }
            }
        }
        let curPortrait = cur.height > cur.width
        var fits: [AVCaptureDevice.Format]
        switch orientation {
        case .auto: fits = candidates(portrait: curPortrait, sameRatio: true)
        case .landscape: fits = candidates(portrait: false, sameRatio: false)
        case .portrait: fits = candidates(portrait: true, sameRatio: false)
        }
        if fits.isEmpty { fits = candidates(portrait: curPortrait, sameRatio: true) }
        return fits.max { a, b in
            let da = a.formatDescription.dimensions, db = b.formatDescription.dimensions
            return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
        } ?? camera.activeFormat
    }
}

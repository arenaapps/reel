import AVFoundation
import CoreMediaIO

/// iPhones and iPads connected by cable show up as capture devices once macOS is told to
/// allow screen-capture devices. The phone has to be unlocked and trust this Mac.
enum IOSDevices {
    static func enable() {
        var prop = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        let status = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &prop, 0, nil,
                                               UInt32(MemoryLayout<UInt32>.size), &allow)
        if status != 0 { Log.record.error("Could not enable iOS screen capture devices: \(status)") }
    }

    static func list() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified).devices
    }
}

/// Records a connected iPhone or iPad screen to screen.mov.
final class IOSScreenRecorder: NSObject, ScreenSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "reel.ios")
    private let output: URL
    private let pause: PauseClock
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var recording = false
    private var lastVideo: CMSampleBuffer?
    private(set) var firstFrameTime: CMTime?
    private(set) var lastFrameTime: CMTime?
    private(set) var pixelSize: CGSize = .zero

    init(device: AVCaptureDevice, output: URL, pause: PauseClock) throws {
        self.output = output
        self.pause = pause
        super.init()
        session.beginConfiguration()
        let deviceInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(deviceInput) else { throw RecorderError.deviceUnavailable }
        session.addInput(deviceInput)
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(out) else { throw RecorderError.deviceUnavailable }
        session.addOutput(out)
        session.commitConfiguration()
    }

    func start() async throws {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                self.session.startRunning()
                self.recording = true
                c.resume()
            }
        }
    }

    func stop(endTime: CMTime) async throws {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                self.recording = false
                // Hold the last frame to the stop time, as the Mac screen recorder does.
                if let last = self.lastVideo, let input = self.input, endTime > (self.lastFrameTime ?? .zero),
                   let copy = last.stamped(at: endTime), input.isReadyForMoreMediaData {
                    input.append(copy)
                    self.lastFrameTime = endTime
                }
                self.lastVideo = nil
                c.resume()
            }
        }
        session.stopRunning()
        guard let writer, let input, firstFrameTime != nil else { throw RecorderError.noDeviceFrames }
        input.markAsFinished()
        writer.endSession(atSourceTime: lastFrameTime ?? endTime)
        await writer.finishWriting()
        if writer.status == .failed { throw writer.error ?? RecorderError.writerFailed }
    }

    func cancel() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { self.recording = false; c.resume() }
        }
        session.stopRunning()
        writer?.cancelWriting()
    }

    private func hostTime(_ t: CMTime) -> CMTime {
        guard let clock = session.synchronizationClock else { return t }
        return CMSyncConvertTime(t, from: clock, to: CMClockGetHostTimeClock())
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard recording, let pixels = sb.imageBuffer else { return }
        let host = hostTime(sb.presentationTimeStamp).seconds
        if pause.isInPause(host) { return }
        let t = CMTime(seconds: pause.toRecording(host), preferredTimescale: 1_000_000_000)
        if writer == nil {
            // The phone's size is only known once frames arrive.
            let w = CVPixelBufferGetWidth(pixels) / 2 * 2, h = CVPixelBufferGetHeight(pixels) / 2 * 2
            guard let writer = try? AVAssetWriter(outputURL: self.output, fileType: .mov) else { return }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: w,
                AVVideoHeightKey: h,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(8_000_000, w * h * 8)]
            ])
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: t)
            self.writer = writer
            self.input = input
            pixelSize = CGSize(width: w, height: h)
            firstFrameTime = t
        }
        guard let input, input.isReadyForMoreMediaData, let frame = sb.stamped(at: t) else { return }
        input.append(frame)
        lastVideo = frame
        lastFrameTime = t
    }
}

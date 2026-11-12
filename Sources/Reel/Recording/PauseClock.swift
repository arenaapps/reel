import CoreMedia
import Foundation

/// Pauses on the host clock, shared by every writer and the input tracker so they all
/// cut the same stretches out of the recording. Thread-safe.
final class PauseClock {
    private let lock = NSLock()
    private var intervals: [(start: Double, end: Double?)] = []

    static var now: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return intervals.last.map { $0.end == nil } ?? false
    }

    func pause(at t: Double = PauseClock.now) {
        lock.lock(); defer { lock.unlock() }
        if intervals.last?.end == nil, !intervals.isEmpty { return }
        intervals.append((t, nil))
    }

    func resume(at t: Double = PauseClock.now) {
        lock.lock(); defer { lock.unlock() }
        guard let last = intervals.last, last.end == nil else { return }
        intervals[intervals.count - 1].end = max(t, last.start)
    }

    func isInPause(_ t: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return intervals.contains { t >= $0.start && t < ($0.end ?? .infinity) }
    }

    /// Host time with the paused stretches before it removed. A time inside a pause maps
    /// to the moment the pause began.
    func toRecording(_ t: Double) -> Double {
        lock.lock(); defer { lock.unlock() }
        var paused = 0.0
        for iv in intervals {
            if t <= iv.start { break }
            let end = iv.end ?? .infinity
            if t < end { return iv.start - paused }
            paused += end - iv.start
        }
        return t - paused
    }
}

extension CMSampleBuffer {
    /// A copy with every timestamp moved earlier by `offset` seconds.
    func shifted(by offset: Double) -> CMSampleBuffer? {
        if offset == 0 { return self }
        let delta = CMTime(seconds: offset, preferredTimescale: 1_000_000_000)
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(self, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(count, 1))
        CMSampleBufferGetSampleTimingInfoArray(self, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count)
        for i in 0..<count {
            infos[i].presentationTimeStamp = infos[i].presentationTimeStamp - delta
            if infos[i].decodeTimeStamp.isValid { infos[i].decodeTimeStamp = infos[i].decodeTimeStamp - delta }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: self, sampleTimingEntryCount: count,
                                              sampleTimingArray: &infos, sampleBufferOut: &out)
        return out
    }

    /// A copy of a single video frame stamped at `time`.
    func stamped(at time: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: self, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }
}

/// Anything that produces screen.mov: the Mac screen, or a connected iPhone/iPad.
protocol ScreenSource: AnyObject {
    /// Host-clock time of the first frame, and of the last frame with pauses removed.
    var firstFrameTime: CMTime? { get }
    var lastFrameTime: CMTime? { get }
    var pixelSize: CGSize { get }
    func start() async throws
    func stop(endTime: CMTime) async throws
    func cancel() async
}

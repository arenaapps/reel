import Foundation
import CoreGraphics

/// Fixed-rate sampled track so the renderer can look up any time cheaply.
struct SampledTrack<T> {
    let rate: Double
    let values: [T]
    func value(at t: Double) -> T? {
        guard !values.isEmpty else { return nil }
        let i = Int((t * rate).rounded())
        return values[min(max(i, 0), values.count - 1)]
    }
}

struct Vec2: Equatable {
    var x: Double, y: Double
    static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: Vec2, k: Double) -> Vec2 { Vec2(x: a.x * k, y: a.y * k) }
}

/// Critically damped spring stepped with semi-implicit Euler.
struct Spring {
    var omega: Double
    func step(_ x: inout Double, _ v: inout Double, target: Double, dt: Double) {
        let a = omega * omega * (target - x) - 2 * omega * v
        v += a * dt
        x += v * dt
    }
}

enum Motion {
    static let rate = 120.0

    /// Linear interpolation of the raw cursor samples at time t.
    static func rawCursor(_ samples: [CursorSample], at t: Double) -> Vec2? {
        guard let first = samples.first else { return nil }
        if t <= first.t { return Vec2(x: first.x, y: first.y) }
        var lo = 0, hi = samples.count - 1
        if t >= samples[hi].t { return Vec2(x: samples[hi].x, y: samples[hi].y) }
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if samples[mid].t <= t { lo = mid } else { hi = mid }
        }
        let a = samples[lo], b = samples[hi]
        let k = (t - a.t) / max(b.t - a.t, 1e-6)
        return Vec2(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
    }

    /// Cursor position after spring smoothing. smoothing 0 returns the raw path.
    static func smoothedCursor(_ samples: [CursorSample], duration: Double, smoothing: Double) -> SampledTrack<Vec2> {
        let n = max(Int(duration * rate) + 1, 1)
        guard !samples.isEmpty else { return SampledTrack(rate: rate, values: []) }
        var out: [Vec2] = []
        out.reserveCapacity(n)
        if smoothing <= 0.01 {
            for i in 0..<n { out.append(rawCursor(samples, at: Double(i) / rate)!) }
            return SampledTrack(rate: rate, values: out)
        }
        let spring = Spring(omega: 40 - 32 * min(max(smoothing, 0), 1))
        var p = rawCursor(samples, at: 0)!
        var vx = 0.0, vy = 0.0
        let dt = 1 / rate
        for i in 0..<n {
            let target = rawCursor(samples, at: Double(i) / rate)!
            spring.step(&p.x, &vx, target: target.x, dt: dt)
            spring.step(&p.y, &vy, target: target.y, dt: dt)
            out.append(p)
        }
        return SampledTrack(rate: rate, values: out)
    }

    /// Cursor opacity per tick: 1 while the cursor moves or clicks, fading to 0 after it
    /// has sat still for `idleAfter` seconds, and back in quickly when it moves again.
    static func idleOpacity(_ samples: [CursorSample], clicks: [ClickEvent], duration: Double,
                            idleAfter: Double = 2.0, fadeOut: Double = 0.4, fadeIn: Double = 0.12) -> SampledTrack<Double> {
        let n = max(Int(duration * rate) + 1, 1)
        // Times at which something happened: movement beyond a hair, or a click.
        var activity: [Double] = clicks.map(\.t)
        var last: CursorSample?
        for s in samples {
            if let l = last, abs(s.x - l.x) + abs(s.y - l.y) > 0.0005 { activity.append(s.t) }
            if last == nil { activity.append(s.t) }
            last = s
        }
        activity.sort()
        var out: [Double] = []
        out.reserveCapacity(n)
        var a = 1.0
        var j = 0
        var lastActive = 0.0
        let dt = 1 / rate
        for i in 0..<n {
            let t = Double(i) / rate
            while j < activity.count, activity[j] <= t { lastActive = activity[j]; j += 1 }
            let target = t - lastActive >= idleAfter ? 0.0 : 1.0
            if target > a { a = min(1, a + dt / fadeIn) } else if target < a { a = max(0, a - dt / fadeOut) }
            out.append(a)
        }
        return SampledTrack(rate: rate, values: out)
    }

    /// Index of the cursor image in effect at time t.
    static func cursorIndex(_ samples: [CursorSample], at t: Double) -> Int? {
        var current: Int?
        for s in samples {
            if s.t > t { break }
            if let c = s.cursor { current = c }
        }
        return current
    }
}

/// Zoom level and focus point over time.
struct CameraState {
    var scale: Double
    var focus: Vec2   // normalised source coordinates
}

extension SampledTrack where T == CameraState {
    /// Linear interpolation between ticks, so sub-frame lookups (motion blur) see smooth motion.
    func interpolated(at t: Double) -> CameraState? {
        guard !values.isEmpty else { return nil }
        let x = min(max(t * rate, 0), Double(values.count - 1))
        let i = Int(x.rounded(.down)), j = min(i + 1, values.count - 1)
        let k = x - Double(i)
        let a = values[i], b = values[j]
        return CameraState(scale: a.scale + (b.scale - a.scale) * k, focus: a.focus + (b.focus - a.focus) * k)
    }
}

enum ZoomPlanner {
    /// One zoom per burst of clicks. Starts a little before the first click so the
    /// camera has arrived by the time the click happens.
    static func autoZooms(clicks: [ClickEvent], duration: Double, scale: Double = 2.0) -> [ZoomSegment] {
        let lead = 0.6, hold = 2.4, mergeGap = 1.0
        var segments: [ZoomSegment] = []
        for c in clicks.sorted(by: { $0.t < $1.t }) {
            let start = max(0, c.t - lead)
            let end = min(duration, c.t + hold)
            if var last = segments.last, start <= last.end + mergeGap {
                last.end = max(last.end, end)
                segments[segments.count - 1] = last
            } else {
                segments.append(ZoomSegment(start: start, end: end, scale: scale))
            }
        }
        return segments.filter { $0.end - $0.start > 0.8 }
    }

    static func cameraTrack(zooms: [ZoomSegment], cursor: SampledTrack<Vec2>, duration: Double, speed: Double) -> SampledTrack<CameraState> {
        let rate = Motion.rate
        let n = max(Int(duration * rate) + 1, 1)
        let dt = 1 / rate
        let scaleSpring = Spring(omega: 3 + 9 * min(max(speed, 0), 1))
        let focusSpring = Spring(omega: 2.5 + 5 * min(max(speed, 0), 1))
        let sorted = zooms.sorted { $0.start < $1.start }
        var s = 1.0, vs = 0.0
        var f = Vec2(x: 0.5, y: 0.5), vfx = 0.0, vfy = 0.0
        var out: [CameraState] = []
        out.reserveCapacity(n)
        var settledFocus = false
        for i in 0..<n {
            let t = Double(i) / rate
            let active = sorted.first { t >= $0.start && t < $0.end }
            let targetScale = active?.scale ?? 1
            var targetFocus = f
            if let z = active {
                if let fx = z.focusX, let fy = z.focusY {
                    targetFocus = Vec2(x: fx, y: fy)
                } else if let c = cursor.value(at: t) {
                    targetFocus = c
                }
                // Jump straight to the first focus point of a zoom while still zoomed out,
                // so the zoom heads for the right place instead of sliding across.
                if !settledFocus && s < 1.05 { f = targetFocus; vfx = 0; vfy = 0 }
                settledFocus = true
            } else {
                settledFocus = false
            }
            scaleSpring.step(&s, &vs, target: targetScale, dt: dt)
            focusSpring.step(&f.x, &vfx, target: targetFocus.x, dt: dt)
            focusSpring.step(&f.y, &vfy, target: targetFocus.y, dt: dt)
            out.append(CameraState(scale: max(1, s), focus: f))
        }
        return SampledTrack(rate: rate, values: out)
    }
}

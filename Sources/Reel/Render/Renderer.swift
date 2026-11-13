import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit
import CoreText

/// Everything needed to draw any frame of a project. Immutable once built,
/// so the compositor can use it from its own thread.
final class RenderState {
    let settings: EditSettings
    let recording: RecordingInfo
    let events: RecordingEvents
    let renderSize: CGSize
    let sourceSize: CGSize          // screen video size in pixels
    let cursorTrack: SampledTrack<Vec2>
    let cameraTrack: SampledTrack<CameraState>
    let cursorIndexTrack: SampledTrack<Int?>
    let cursorOpacity: SampledTrack<Double>
    let cursorImages: [Int: (image: CIImage, info: CursorImage)]
    let fallbackCursor: (image: CIImage, info: CursorImage)?
    let backgroundImage: CIImage?
    let layout: Layout
    let mappedTimeline: EditTimeline
    /// The shortcut pill for each distinct shortcut, drawn once at output size.
    let keyImages: [String: CIImage]

    struct Layout {
        let screenRect: CGRect      // top-left origin, output pixels
        let sourceToCanvas: CGFloat
        let pointToCanvas: CGFloat  // recorded points -> output pixels
        let unit: CGFloat           // output pixels per "1080p pixel"
    }

    init(settings: EditSettings, recording: RecordingInfo, events: RecordingEvents, folder: URL,
         renderSize: CGSize, sourceSize: CGSize) {
        self.settings = settings
        self.recording = recording
        self.events = events
        self.renderSize = renderSize
        self.sourceSize = sourceSize
        mappedTimeline = EditTimeline(settings, duration: recording.duration)
        let duration = recording.duration
        cursorTrack = Motion.smoothedCursor(events.samples, duration: duration, smoothing: settings.cursorSmoothing)
        cameraTrack = ZoomPlanner.cameraTrack(zooms: settings.zooms, cursor: Motion.smoothedCursor(events.samples, duration: duration, smoothing: 0.95),
                                              duration: duration, speed: settings.zoomSpeed)
        // Cursor shape per tick.
        var idx: [Int?] = []
        let n = max(Int(duration * Motion.rate) + 1, 1)
        idx.reserveCapacity(n)
        var current: Int?
        var j = 0
        let samples = events.samples
        for i in 0..<n {
            let t = Double(i) / Motion.rate
            while j < samples.count, samples[j].t <= t {
                if let c = samples[j].cursor { current = c }
                j += 1
            }
            idx.append(current)
        }
        cursorIndexTrack = SampledTrack(rate: Motion.rate, values: idx)
        cursorOpacity = Motion.idleOpacity(events.samples, clicks: events.clicks, duration: duration)

        var images: [Int: (CIImage, CursorImage)] = [:]
        for (i, c) in events.cursors.enumerated() {
            if let img = CIImage(contentsOf: folder.appendingPathComponent(c.file)) { images[i] = (img, c) }
        }
        cursorImages = images
        fallbackCursor = Self.drawnArrow()
        var keyImgs: [String: CIImage] = [:]
        if settings.showKeys {
            let u = renderSize.height / 1080 * CGFloat(settings.keysScale) * 2
            for k in events.keys where keyImgs[k.keys.joined(separator: " ")] == nil {
                keyImgs[k.keys.joined(separator: " ")] = Self.keyPill(k.keys, unit: u)
            }
        }
        keyImages = keyImgs
        if case .image(let path) = settings.background {
            backgroundImage = CIImage(contentsOf: URL(fileURLWithPath: path))
        } else {
            backgroundImage = nil
        }

        let unit = min(renderSize.width, renderSize.height) / 1080
        let pad = CGFloat(settings.padding) * min(renderSize.width, renderSize.height)
        let avail = CGRect(origin: .zero, size: renderSize).insetBy(dx: pad, dy: pad)
        let k = min(avail.width / max(sourceSize.width, 1), avail.height / max(sourceSize.height, 1))
        let size = CGSize(width: sourceSize.width * k, height: sourceSize.height * k)
        let rect = CGRect(x: avail.midX - size.width / 2, y: avail.midY - size.height / 2, width: size.width, height: size.height)
        layout = Layout(screenRect: rect, sourceToCanvas: k,
                        pointToCanvas: rect.width / CGFloat(max(recording.sourcePointWidth, 1)), unit: unit)
    }

    var trimEnd: Double { min(settings.trimEnd ?? recording.duration, recording.duration) }
    var outputDuration: Double { max(0.1, mappedTimeline.length) }

    /// A dark rounded pill with one key cap per label, as in the Figma sketch, at `unit` px per 1080p px.
    static func keyPill(_ labels: [String], unit u: CGFloat) -> CIImage? {
        let font = CTFontCreateWithName("SF Pro Text Semibold" as CFString, 20 * u, nil)
        let lines = labels.map { l -> (CTLine, CGRect) in
            let a = NSAttributedString(string: l, attributes: [.font: font, .foregroundColor: CGColor(gray: 1, alpha: 1)])
            let line = CTLineCreateWithAttributedString(a)
            return (line, CTLineGetBoundsWithOptions(line, .useOpticalBounds))
        }
        let capPadX = 12 * u, capPadY = 6 * u, gap = 6 * u, padX = 10 * u, padY = 8 * u
        let textH = 20 * u * 1.2
        let capH = textH + 2 * capPadY
        let capWs = lines.map { max($0.1.width + 2 * capPadX, capH) }
        let W = capWs.reduce(0, +) + gap * CGFloat(max(0, lines.count - 1)) + 2 * padX
        let H = capH + 2 * padY
        guard let ctx = CGContext(data: nil, width: Int(ceil(W)), height: Int(ceil(H)), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: W, height: H), cornerWidth: 12 * u, cornerHeight: 12 * u, transform: nil))
        ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 0.82))
        ctx.fillPath()
        var x = padX
        for (i, (line, b)) in lines.enumerated() {
            let cw = capWs[i]
            ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: padY, width: cw, height: capH), cornerWidth: 7 * u, cornerHeight: 7 * u, transform: nil))
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.12))
            ctx.fillPath()
            ctx.textPosition = CGPoint(x: x + (cw - b.width) / 2 - b.minX, y: padY + (capH - b.height) / 2 - b.minY)
            CTLineDraw(line, ctx)
            x += cw + gap
        }
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }

    /// An anti-aliased ring: a disk with a smaller disk taken out of it.
    static func ring(center: CGPoint, radius r: CGFloat, width w: CGFloat, alpha: CGFloat) -> CIImage {
        func disk(_ rr: CGFloat, _ a: CGFloat) -> CIImage {
            let g = CIFilter.radialGradient()
            g.center = center
            g.radius0 = Float(max(0, rr - 0.75))
            g.radius1 = Float(rr + 0.75)
            g.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: a)
            g.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
            return g.outputImage!
        }
        let box = CGRect(x: center.x - r - 2, y: center.y - r - 2, width: 2 * r + 4, height: 2 * r + 4)
        return disk(r, alpha)
            .applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: disk(max(0, r - w), 1)])
            .cropped(to: box)
    }

    /// A macOS-style arrow drawn at 4x, used when no cursor image was captured.
    static func drawnArrow() -> (image: CIImage, info: CursorImage)? {
        let scale: CGFloat = 4
        let w: CGFloat = 18, h: CGFloat = 26
        guard let ctx = CGContext(data: nil, width: Int(w * scale), height: Int(h * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)   // draw in top-left coordinates
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 2, y: 2))
        p.addLine(to: CGPoint(x: 2, y: 20))
        p.addLine(to: CGPoint(x: 6.5, y: 15.8))
        p.addLine(to: CGPoint(x: 9.6, y: 22.6))
        p.addLine(to: CGPoint(x: 12.4, y: 21.4))
        p.addLine(to: CGPoint(x: 9.4, y: 14.8))
        p.addLine(to: CGPoint(x: 15.2, y: 14.8))
        p.closeSubpath()
        ctx.addPath(p)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(2.2)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.strokePath()
        ctx.addPath(p)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        guard let cg = ctx.makeImage() else { return nil }
        return (CIImage(cgImage: cg), CursorImage(file: "", hotspotX: 2, hotspotY: 2, width: w, height: h))
    }

    // MARK: drawing

    private lazy var background: CIImage = makeBackground()

    private func makeBackground() -> CIImage {
        let extent = CGRect(origin: .zero, size: renderSize)
        switch settings.background {
        case .solid(let c):
            return CIImage(color: c.ci).cropped(to: extent)
        case .gradient(let a, let b, let angle):
            let rad: CGFloat = CGFloat(angle) * CGFloat.pi / 180
            let c = CGPoint(x: extent.midX, y: extent.midY)
            let cr: CGFloat = cos(rad), sr: CGFloat = sin(rad)
            let half: CGFloat = (abs(cr) * extent.width + abs(sr) * extent.height) / 2
            let d = CGPoint(x: cr * half, y: -sr * half)
            let f = CIFilter.linearGradient()
            f.point0 = CGPoint(x: c.x - d.x, y: c.y - d.y)
            f.point1 = CGPoint(x: c.x + d.x, y: c.y + d.y)
            f.color0 = a.ci
            f.color1 = b.ci
            return f.outputImage!.cropped(to: extent)
        case .image:
            guard let img = backgroundImage else { return CIImage(color: .black).cropped(to: extent) }
            let s = max(extent.width / img.extent.width, extent.height / img.extent.height)
            let scaled = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
            let dx = (extent.width - scaled.extent.width) / 2 - scaled.extent.minX
            let dy = (extent.height - scaled.extent.height) / 2 - scaled.extent.minY
            return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: extent)
        }
    }

    /// Converts a top-left rect to Core Image's bottom-left space.
    private func ci(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: renderSize.height - r.maxY, width: r.width, height: r.height)
    }

    private func roundedMask(_ rect: CGRect, radius: CGFloat) -> CIImage {
        let f = CIFilter.roundedRectangleGenerator()
        f.extent = rect
        f.radius = Float(min(radius, min(rect.width, rect.height) / 2))
        f.color = .white
        return f.outputImage!
    }

    /// Draws one output frame. `t` is time in the source recording (seconds).
    func render(screen: CIImage?, camera: CIImage?, at t: Double) -> CIImage {
        let canvasExtent = CGRect(origin: .zero, size: renderSize)
        let L = layout
        let screenCI = ci(L.screenRect)
        let radius = CGFloat(settings.cornerRadius) * L.unit

        // Screen layer, scaled into place.
        var layer: CIImage
        if let screen {
            let sx = L.screenRect.width / screen.extent.width
            let sy = L.screenRect.height / screen.extent.height
            layer = screen
                .transformed(by: CGAffineTransform(translationX: -screen.extent.minX, y: -screen.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                .transformed(by: CGAffineTransform(translationX: screenCI.minX, y: screenCI.minY))
        } else {
            layer = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.12)).cropped(to: screenCI)
        }

        // Cursor and click ripple.
        let cursorAlpha = settings.hideIdleCursor ? CGFloat(cursorOpacity.value(at: t) ?? 1) : 1
        if settings.showCursor, cursorAlpha > 0.01, let p = cursorTrack.value(at: t) {
            let pos = CGPoint(x: L.screenRect.minX + CGFloat(p.x) * L.screenRect.width,
                              y: L.screenRect.minY + CGFloat(p.y) * L.screenRect.height)
            var press: CGFloat = 0
            if settings.clickEffect {
                // A thin white ring that grows from the pointer's tip and fades (no blur).
                let px = L.pointToCanvas * CGFloat(settings.cursorScale)
                for c in events.clicks where c.t <= t && t - c.t < 0.45 {
                    let k = CGFloat((t - c.t) / 0.45)
                    press = max(press, 1 - k)
                    let grow = 1 - (1 - k) * (1 - k)
                    let r = (5 + 19 * grow) * px
                    let w = max(2 * L.unit, 1.6 * px)
                    layer = Self.ring(center: CGPoint(x: pos.x, y: renderSize.height - pos.y), radius: r, width: w,
                                      alpha: 0.9 * (1 - k)).composited(over: layer)
                }
            }
            let idx = cursorIndexTrack.value(at: t) ?? nil
            if let cur = idx.flatMap({ cursorImages[$0] }) ?? fallbackCursor {
                let scale = L.pointToCanvas * CGFloat(settings.cursorScale) * (1 - 0.12 * press)
                let wPx = CGFloat(cur.info.width) * scale
                let k = wPx / cur.image.extent.width
                let hot = CGPoint(x: CGFloat(cur.info.hotspotX) * scale, y: CGFloat(cur.info.hotspotY) * scale)
                let hPx = cur.image.extent.height * k
                let x = pos.x - hot.x
                let yTop = pos.y - hot.y
                var img = cur.image
                    .transformed(by: CGAffineTransform(translationX: -cur.image.extent.minX, y: -cur.image.extent.minY))
                    .transformed(by: CGAffineTransform(scaleX: k, y: k))
                    .transformed(by: CGAffineTransform(translationX: x, y: renderSize.height - yTop - hPx))
                if cursorAlpha < 0.999 { img = Self.fade(img, cursorAlpha) }
                let shadow = img.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.35)
                ]).applyingGaussianBlur(sigma: Double(2 * L.unit)).transformed(by: CGAffineTransform(translationX: 0, y: -2 * L.unit))
                layer = img.composited(over: shadow.composited(over: layer))
            }
        }

        // Round the corners and drop a shadow.
        let mask = roundedMask(screenCI, radius: radius)
        let rounded = layer.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask
        ]).cropped(to: screenCI)
        var canvas = background
        if settings.shadow > 0.01 {
            let blur = Double(40 * L.unit)
            let shadow = roundedMask(screenCI, radius: radius)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(0.55 * settings.shadow))
                ])
                .applyingGaussianBlur(sigma: blur)
                .transformed(by: CGAffineTransform(translationX: 0, y: -14 * L.unit))
            canvas = shadow.composited(over: canvas)
        }
        canvas = rounded.composited(over: canvas).cropped(to: canvasExtent)

        // Zoom: crop a viewport around the focus point and scale it back up. While the camera
        // moves, average sub-frames across a virtual shutter so the move blurs like real footage.
        if let cam = cameraTrack.interpolated(at: t) {
            let shutter = (1.0 / 30) * min(max(settings.motionBlur, 0), 1)
            if shutter > 0.001, let streak = cameraStreak(from: t - shutter, to: t), streak > 1.5 {
                // About one sub-frame per 2 px of travel keeps the streak continuous.
                let n = min(32, max(4, Int(streak / 2) + 1))
                let source = canvas.insertingIntermediate(cache: true)   // draw the canvas once, sample it n times
                var acc: CIImage?
                for k in 0..<n {
                    let ts = t - shutter * Double(k) / Double(n - 1)
                    guard let c = cameraTrack.interpolated(at: ts) else { continue }
                    let frame = Self.fade(zoomed(source, c), 1 / CGFloat(n))
                    acc = acc.map { frame.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? frame
                }
                canvas = (acc ?? zoomed(canvas, cam)).cropped(to: canvasExtent)
            } else if cam.scale > 1.001 {
                canvas = zoomed(canvas, cam)
            }
        }

        // Camera bubble, fixed on the canvas.
        if settings.showCamera, let camera {
            let d = CGFloat(settings.cameraSize) * renderSize.height
            let margin = max(24 * L.unit, CGFloat(settings.padding) * min(renderSize.width, renderSize.height) * 0.5)
            let side = min(camera.extent.width, camera.extent.height)
            let crop = CGRect(x: camera.extent.midX - side / 2, y: camera.extent.midY - side / 2, width: side, height: side)
            let k = d / side
            var x: CGFloat = margin, yTop: CGFloat = renderSize.height - margin - d
            switch settings.cameraCorner {
            case .bottomLeft: break
            case .bottomRight: x = renderSize.width - margin - d
            case .topLeft: yTop = margin
            case .topRight: x = renderSize.width - margin - d; yTop = margin
            }
            let rect = CGRect(x: x, y: renderSize.height - yTop - d, width: d, height: d)
            let cam = camera.cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                .transformed(by: CGAffineTransform(scaleX: -k, y: k))   // mirror like a selfie view
                .transformed(by: CGAffineTransform(translationX: rect.maxX, y: rect.minY))
            let r = settings.cameraShape == .circle ? d / 2 : d * 0.18
            let m = roundedMask(rect, radius: r)
            let bubble = cam.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: m
            ]).cropped(to: rect)
            let shadow = m.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.4)
            ]).applyingGaussianBlur(sigma: Double(18 * L.unit)).transformed(by: CGAffineTransform(translationX: 0, y: -6 * L.unit))
            canvas = bubble.composited(over: shadow.composited(over: canvas)).cropped(to: canvasExtent)
        }
        // Shortcut overlay: the latest shortcut, for 1.2 s, fixed on the canvas over the screen.
        if settings.showKeys, let k = events.keys.last(where: { $0.t <= t }), t - k.t < 1.2,
           let pill = keyImages[k.keys.joined(separator: " ")] {
            let age = t - k.t
            let alpha = CGFloat(min(1, age / 0.08, (1.2 - age) / 0.25))
            let u = renderSize.height / 1080 * CGFloat(settings.keysScale) * 2
            let w = pill.extent.width, h = pill.extent.height
            let x = L.screenRect.midX - w / 2
            let yTop = settings.keysPosition == .bottom ? L.screenRect.maxY - 16 * u - h : L.screenRect.minY + 16 * u
            var img = pill.transformed(by: CGAffineTransform(translationX: x - pill.extent.minX,
                                                             y: renderSize.height - yTop - h - pill.extent.minY))
            if alpha < 0.999 { img = Self.fade(img, max(0, alpha)) }
            canvas = img.composited(over: canvas).cropped(to: canvasExtent)
        }
        return canvas
    }
}

extension RenderState {
    /// Multiplies an image's opacity. CIColorMatrix works on un-premultiplied colour,
    /// so only alpha is scaled; Core Image premultiplies the result again.
    static func fade(_ image: CIImage, _ alpha: CGFloat) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
    }

    /// Top-left origin of the zoom viewport and its scale, in output pixels.
    func viewport(_ cam: CameraState) -> (x: CGFloat, y: CGFloat, s: CGFloat) {
        let L = layout
        let s = CGFloat(max(cam.scale, 1))
        let fx = L.screenRect.minX + CGFloat(cam.focus.x) * L.screenRect.width
        let fy = L.screenRect.minY + CGFloat(cam.focus.y) * L.screenRect.height
        let vw = renderSize.width / s, vh = renderSize.height / s
        return (min(max(fx - vw / 2, 0), renderSize.width - vw), min(max(fy - vh / 2, 0), renderSize.height - vh), s)
    }

    /// The canvas seen through the zoom viewport for one camera state.
    func zoomed(_ canvas: CIImage, _ cam: CameraState) -> CIImage {
        let v = viewport(cam)
        let vyCI = renderSize.height - v.y - renderSize.height / v.s
        return canvas
            .transformed(by: CGAffineTransform(translationX: -v.x, y: -vyCI))
            .transformed(by: CGAffineTransform(scaleX: v.s, y: v.s))
            .cropped(to: CGRect(origin: .zero, size: renderSize))
    }

    /// The longest distance, in output pixels, any frame corner travels between two times.
    /// Used to decide whether the camera moved enough to need blur, and how many sub-frames.
    func cameraStreak(from t0: Double, to t1: Double) -> CGFloat? {
        guard t0 >= 0, let a = cameraTrack.interpolated(at: t0), let b = cameraTrack.interpolated(at: t1) else { return nil }
        let va = viewport(a), vb = viewport(b)
        var longest: CGFloat = 0
        for (x, y) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
            // The content point under this output corner now, and where it was shown at t0.
            let px = vb.x + CGFloat(x) * renderSize.width / vb.s, py = vb.y + CGFloat(y) * renderSize.height / vb.s
            let ox = (px - va.x) * va.s, oy = (py - va.y) * va.s
            longest = max(longest, hypot(ox - CGFloat(x) * renderSize.width, oy - CGFloat(y) * renderSize.height))
        }
        return longest
    }
}

extension RGBA {
    var ci: CIColor { CIColor(red: r, green: g, blue: b, alpha: a) }
}

enum RenderSizing {
    /// Output size for an aspect and a short-side length.
    static func size(aspect: AspectPreset, source: CGSize, shortSide: CGFloat) -> CGSize {
        let ratio = aspect.ratio(source: source)
        var w: CGFloat, h: CGFloat
        if ratio >= 1 { h = shortSide; w = shortSide * ratio } else { w = shortSide; h = shortSide / ratio }
        return CGSize(width: (w / 2).rounded() * 2, height: (h / 2).rounded() * 2)
    }
}

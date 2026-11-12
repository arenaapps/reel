# Reel

A native macOS screen recorder in the style of Screen Studio. It records the screen, then turns the raw recording into a polished video: automatic zoom on clicks with motion blur, a smoothed and enlarged cursor that hides when still, a background with padding, rounded corners and a shadow, and a camera bubble.

Swift 5 language mode, SwiftUI, ScreenCaptureKit, AVFoundation and Core Image. macOS 14 or later.

## Build and run

```bash
./scripts/bundle.sh          # release build into build/Reel.app
open build/Reel.app
```

The first launch asks for Screen Recording permission (System Settings > Privacy & Security > Screen Recording). Camera and microphone ask on first use.

Development shortcut: `open build/Reel.app --args --open /path/to/Some.reel` opens a project in the editor straight away.

## Tests

```bash
swift test --filter MotionTests                       # fast maths tests
REEL_FIXTURE=/path/to/fixture.reel swift test --filter RenderPipelineTests   # full render + MP4 + GIF export
```

A fixture folder needs `screen.mov` and `events.json`, plus optional `camera.mov` and `mic.m4a`. ffmpeg's `testsrc2` makes a good fake screen.

## How it works

- `Recording/` writes `screen.mov` (HEVC, no cursor, optional system audio) through ScreenCaptureKit, `camera.mov` and `mic.m4a` through AVCaptureSession, and logs cursor position (120 Hz), clicks and cursor shapes. Everything is stamped on the host clock, so the files line up.
- A project is a folder `~/Movies/Reel/<name>.reel` holding the media, `events.json` and `project.json` (edit settings).
- `Render/Motion.swift` precomputes the smoothed cursor path and the zoom camera (spring physics, 120 samples a second). `ZoomPlanner.autoZooms` turns bursts of clicks into zoom segments.
- `Render/Renderer.swift` draws one frame from a screen frame and a camera frame. `ReelCompositor` plugs it into AVFoundation, so the live preview (AVPlayer) and the export (AVAssetExportSession) draw the exact same pixels.
- `Export/Exporter.swift` writes MP4 at 720p to 4K at 30 or 60 fps, or a GIF.

## Shortcuts

- ⌘⇧2 starts and stops a recording from anywhere.
- Space plays and pauses in the editor.

## Signing

macOS ties the Screen Recording permission to the app's signature. To keep it between rebuilds, sign with a stable certificate: put `REEL_SIGN_IDENTITY=<certificate hash or name>` in `scripts/sign.local` (gitignored). Without it the build is signed ad hoc and macOS asks again after each rebuild.

## Licence

MIT. See [LICENSE](LICENSE).

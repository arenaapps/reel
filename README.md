# Reel

A native macOS screen recorder in the style of Screen Studio. It records the screen, then turns the raw recording into a polished video: automatic zoom on clicks with motion blur, a smoothed and enlarged cursor that hides when still, a background with padding, rounded corners and a shadow, and a camera bubble.

Swift 5 language mode, SwiftUI, ScreenCaptureKit, AVFoundation and Core Image. macOS 14 or later.

In the editor you can split the clip (S or ⌘B), cut pieces out (Delete), speed pieces up (1.5× to 8×, with [ and ]), split and resize zooms, nudge the mic against the video, show keyboard shortcuts on screen, and save a look to reuse on every recording.

## Install

Download `Reel-<version>.zip` from the Releases page, unzip it and drag Reel into Applications. It runs on Apple silicon and Intel Macs with macOS 14 or later.

If macOS says it can't check Reel for malicious software, right-click Reel in Applications, choose Open, then Open again. That happens with builds that aren't notarised.

Reel lives in the menu bar. It asks for Screen Recording permission on first launch, and for the camera and microphone when you first pick them. Recording keyboard shortcuts is off by default; turning it on asks for Accessibility permission. Only keys pressed with ⌘, ⌃ or ⌥, plus Esc, Return, Tab and the arrows, are saved. Plain typing is never stored.

## Build and run

```bash
./scripts/bundle.sh          # release build into build/Reel.app
open build/Reel.app
```

The first launch asks for Screen Recording permission (System Settings > Privacy & Security > Screen Recording). Camera and microphone ask on first use.

Development shortcut: `open build/Reel.app --args --open /path/to/Some.reel` opens a project in the editor straight away.

## Release

```bash
./scripts/release.sh         # universal build, zipped into build/Reel-<version>.zip
```

Set `REEL_RELEASE_IDENTITY` (a Developer ID Application certificate) and `REEL_NOTARY_PROFILE` (a `notarytool` keychain profile) in `scripts/sign.local` to sign and notarise. Without them the zip is signed ad hoc. The script replaces `build/Reel.app`, so run `./scripts/bundle.sh` afterwards for your own copy.

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

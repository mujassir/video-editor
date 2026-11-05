# Cutline

A fast, private video editor for iPhone. It's built natively in Swift, SwiftUI, UIKit and Metal, and all AI features run **on the device**: no account, no uploads, no watermark (unless you add your own).

> "Cutline" is a working name.

- **Platform:** iOS 26+, iPhone 15 and newer (Mac is planned next).
- **Stack:**
  - Swift 6 with strict concurrency.
  - SwiftUI screens plus a UIKit timeline.
  - A Metal compositor on AVFoundation.
  - Apple's on-device frameworks: Vision, Speech, Accelerate and Core Image.
- **Dependencies:** none. No third-party packages, web views, FFmpeg or cloud APIs.

## Features

### Projects
- Project library with thumbnails: rename, duplicate, delete.
- Autosave, plus undo and redo of up to 200 steps.
- Empty projects aren't kept.
- Import from Photos or Files: video, photos and audio.

### Timeline and preview
- Live preview rendered by the Metal compositor, with no black flash after edits.
- UIKit timeline:
  - Centre playhead, pinch to zoom, filmstrip thumbnails.
  - Audio waveforms.
  - Lanes for text, captions and music.
- Animations play only during playback. Paused or scrubbing, the preview shows clips at rest, so edits are easy to judge.

### Video clips
- Split, trim (drag the clip's handles on the timeline), duplicate, reorder and delete.
- Speed from 0.1× to 10×, reverse, freeze frame, volume, extract audio.
- 20 filters (3D lookup tables), plus adjustments: exposure, contrast, saturation, warmth, highlights, shadows, vignette, sharpen.
- Crop, rotate, flip, zoom; Fit, Fill or Stretch per clip.
- 8 transitions: fade, dissolve, slide, push, zoom, wipe, blur, glitch.

### Photos
- A photo-only toolbar.
- **Duration:** 0.5–30 s, with presets and "apply to all photos".
- **Motion:** zoom in/out, pan in 4 directions, Ken Burns.

### Animations (clips, photos and text)
- **In:** fade, zoom in/out, slide in 4 directions, rotate, spin, pop, bounce, drop, blur, swing.
- **Out:** the same set, played in reverse.
- **Combo** (loops for the whole clip): pulse, heartbeat, shake, wobble, swing, float, rock, spin.
- In and Out lengths go up to 3 s, and can be applied to all clips.

### Text
- Fonts, colour, outline, label and shadow.
- **Duration**, **Animate** (In/Out/Combo), **Position** (a 3×3 grid of fixed spots that keep the text inside the video), **Duplicate**.
- Drag the text on the video to place it anywhere (Custom position).

### Music and audio
- 4 built-in royalty-free tracks, synthesized on the device.
- Your own music from **Files**, or the soundtrack of a video (**From Video**).
- **Music toolbar:** Edit, Repeat (loops the track's section until the end of the video), Duplicate, Delete.
- **Edit Audio:**
  - One range slider over the song's waveform.
  - Play the selected section, with a moving cursor.
  - Trim, Volume, Undo, and ✓ to save.
- Press and hold a music bar, then drag it, to move it.
- Music follows the video's length as you add or remove content. Choosing an End yourself switches this off, and **Match video** (in Edit Audio) switches it back on.
- Fade-out, and automatic ducking of music under speech.

### Canvas
- 9:16, 3:4, 1:1, 4:5 and 16:9, with a blurred background.
- **Media that doesn't fit:** Fit, Fill or Stretch, with Center, Top, Bottom, Left or Right position, for all clips.

### Opening and closing slides
- **Intro** and **Outro** title cards: title, subtitle, 7 style presets, duration. ✓ saves.
- The cards fill any canvas ratio, and animations and transitions work on them.

### Watermark
- Text, or an image from Photos.
- 9 positions, plus size and opacity.
- Drawn over the whole video, including exports.

### On-device AI
- **Auto captions:** Apple's on-device speech recognition, with word timing and 5 animated styles. It never falls back to server recognition.
- **Auto enhance:** corrects exposure, contrast, colour and white balance.
- **Auto reframe:** follows faces and subjects so a wide shot fits a vertical canvas.
- **Background removal (Cutout):** person segmentation with blur, colour or transparent background.

### Export
- 720p, 1080p or 4K at 24, 30 or 60 fps, in HEVC or H.264, using the hardware encoder.
- An estimated file size before export, and the real size after it.
- Save to Photos, or share.

## Open in Xcode

Requires **Xcode 26** or newer.

```bash
git clone https://github.com/mujassir/video-editor.git
```
```bash
cd video-editor
```
```bash
open Cutline.xcodeproj
```

Choose the **Cutline** scheme and an iPhone simulator or your iPhone, then Run (⌘R).
- **Signing:** the team is set in `project.yml` (`DEVELOPMENT_TEAM`) and in the committed project. To use your own, change it under *Signing & Capabilities* for the **Cutline** target, and change the bundle ID if needed.

### Regenerating the Xcode project

`Cutline.xcodeproj` is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). Regenerate it after adding or removing source files, or after editing `project.yml`:

```bash
brew install xcodegen
```
```bash
xcodegen generate
```

## Project layout

```
App/                      iPhone app (SwiftUI + UIKit)
  ProjectsView.swift      project library, root view
  Editor/
    EditorModel.swift     editing session, preview player, AI jobs
    EditorView.swift      editor screen, toolbars
    TimelineView.swift    UIKit timeline (thumbnails, waveforms, trim handles, drag)
    PreviewView.swift     Metal preview, text dragging
    Panels.swift          tool panels (canvas, trim, filters, animate, text, music, …)
    ExportView.swift      export settings, progress, size estimate
EditorKit/                framework: everything except UI
  Model/                  project model, value-type editing operations, undo/redo, storage
  Engine/                 composition builder, Metal compositor and shaders, filters,
                          text/caption/title rendering, export, thumbnails, waveforms
  Intelligence/           captions, silence, beats, reframe, enhance, segmentation
Tests/
  EditorKitTests/         unit tests (Swift Testing)
  CutlineUITests/         one UI test per feature (XCTest)
project.yml               XcodeGen project definition
```

## Tests and CI

GitHub Actions (`.github/workflows/ios.yml`) builds the app and runs every test on an iPhone 17 Pro simulator, for every push:

- **100 unit tests:**
  - Editing rules, timing and layout.
  - Rendered-frame checks of filters, transitions, text, animations, watermark and photo motion.
  - Export.
  - Beat, silence, reframe and enhance analysis.
- **22 UI tests,** one per feature.

Run them locally:

```bash
xcodebuild test -project Cutline.xcodeproj -scheme Cutline -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

A few unit tests use sound and image fixtures that CI generates (`Tests/EditorKitTests/Fixtures`). Without them, those tests record a known issue.

### Known limitations

- **Not verifiable in the simulator:** the iOS simulator doesn't include Apple's on-device **speech** or **person-segmentation** models. Auto captions and Cutout background removal therefore need testing on a physical iPhone 15 or newer, and the related tests are marked as expected failures in the simulator.
- **Performance:** export speed in the simulator uses software encoding. Real-device performance, with the hardware encoder and Neural Engine, hasn't been measured yet.

## License

See [LICENSE](LICENSE).

# Cutline: Implementation Specification

**Status:** derived from the iOS reference implementation (Swift, `EditorKit` plus `App`).
**Read first:** [FEATURES.md](FEATURES.md), which describes what the user sees. This document says how to build it so every platform behaves the same.
**Contract file:** [project.sample.json](project.sample.json), checked by the iOS test `ProjectFileContractTests`.

> **Rule for humans and AI agents:** numbers, names and formulas here are the contract. When you port a feature, copy them exactly. If you must deviate (a platform limit), record it in the FEATURES.md parity table and here, in the section concerned.

---

## 1. Architecture

### 1.1 Layers

```
┌──────────────────────────────────────────────────────────────┐
│ UI (per platform): SwiftUI+UIKit · Jetpack Compose · …       │  screens, panels, gestures
├──────────────────────────────────────────────────────────────┤
│ Editor state: EditorModel (selection, panel, playback,       │  glue: calls Core, schedules rebuilds
│ busy/toast, autosave)                                        │
├───────────────┬───────────────────┬──────────────────────────┤
│ Core (pure)   │ Engine            │ Intelligence             │
│ Model, edits, │ composition,      │ captions, enhance,       │
│ time, layout, │ GPU compositor,   │ reframe, segmentation,   │
│ undo, storage │ text raster,      │ noise reduction,         │
│               │ export, import    │ beats, silence           │
└───────────────┴───────────────────┴──────────────────────────┘
```

- **Core** has no UI, GPU or media framework dependencies. On iOS it's `EditorKit/Model/*`. Every edit is a **pure function on a value-type `Project`**: `Project` in, new `Project` out. Port it first and test it heavily; it's where behaviour lives.
- **Engine** turns a `Project` into frames and samples. It only reads the project.
- **Intelligence** returns plain data (adjustments, keyframes, words, beats), which the UI applies as an edit.
- **The UI never changes `Project` directly.** It always goes through the edit session (§5).

### 1.2 iOS reference map

| Concern | iOS file |
|---|---|
| Time | `EditorKit/Model/MediaTime.swift` |
| Data model | `EditorKit/Model/Project.swift` |
| Edit operations | `EditorKit/Model/Editing.swift` |
| Timeline layout | `EditorKit/Model/TimelineLayout.swift` |
| Undo/redo | `EditorKit/Model/EditSession.swift` |
| Storage, autosave | `EditorKit/Model/ProjectStore.swift` |
| Recent audio tracks (MUS-10) | `EditorKit/Model/RecentAudioStore.swift` |
| Playback/export graph | `EditorKit/Engine/CompositionBuilder.swift` |
| Per-frame compositor | `EditorKit/Engine/VideoCompositor.swift`, `MetalRenderer.swift`, `Shaders.metal` |
| Geometry and animation maths | `EditorKit/Engine/LayerGeometry.swift` |
| Filters | `EditorKit/Engine/FilterLibrary.swift` |
| Text, captions, slides | `EditorKit/Engine/TextRasterizer.swift` |
| Export | `EditorKit/Engine/Exporter.swift` |
| Import, probing | `EditorKit/Engine/MediaImporter.swift` |
| Built-in music | `EditorKit/Engine/SampleMedia.swift` |
| Captions | `EditorKit/Intelligence/CaptionGenerator.swift` |
| Enhance, reframe, segmentation | `EditorKit/Intelligence/VisualAnalysis.swift` |
| Noise reduction, beats, silence | `EditorKit/Intelligence/AudioAnalysis.swift` |
| Editor state | `App/Editor/EditorModel.swift` |
| Toolbars | `App/Editor/EditorView.swift` |
| Panels | `App/Editor/Panels.swift` |
| Timeline UI | `App/Editor/TimelineView.swift` |
| Export UI | `App/Editor/ExportView.swift` |

### 1.3 Platform technology map

The iOS app uses **no third-party code**. Other platforms should prefer the operating system's own frameworks the same way. Where they need a library, it must run fully offline.

| Need | iOS | Android (suggested) | macOS | Windows (suggested) |
|---|---|---|---|---|
| Language/UI | Swift 6, SwiftUI plus UIKit timeline | Kotlin, Jetpack Compose (custom `View` or Canvas for the timeline) | Swift, SwiftUI plus AppKit (share `EditorKit`) | C#/WinUI 3 or C++ |
| Decode/compose/play | AVFoundation (`AVMutableComposition`, custom `AVVideoCompositing`) | Media3 ExoPlayer + `MediaCodec`; Media3 Transformer, or own GL pipeline | Same as iOS | Media Foundation |
| GPU compositor | Metal | OpenGL ES 3 / Vulkan (port the shaders in §8) | Metal (same code) | Direct3D 11/12 (port the shaders) |
| Encode | `AVAssetExportSession` (HEVC/H.264 hardware) | `MediaCodec` + `MediaMuxer` | Same as iOS | Media Foundation hardware MFT |
| Speech to text | `SpeechAnalyzer`/`SpeechTranscriber` (iOS 26), fallback `SFSpeechRecognizer` with on-device forced | `SpeechRecognizer.createOnDeviceSpeechRecognizer` (Android 13+) or bundled whisper.cpp | Same as iOS | Windows on-device speech or whisper.cpp |
| Faces, saliency | Vision `VNDetectFaceRectanglesRequest`, `VNGenerateObjectnessBasedSaliencyImageRequest` | ML Kit Face Detection (bundled), MediaPipe | Vision | Windows.Media.FaceAnalysis, ONNX |
| Person segmentation | Vision `VNGeneratePersonSegmentationRequest` (`.balanced` preview, `.accurate` export) | MediaPipe Selfie Segmentation / ML Kit Subject Segmentation (bundled) | Vision | ONNX model (offline) |
| DSP/FFT | Accelerate (vDSP) | JTransforms or own radix-2 FFT (Kotlin), or C++ via JNI | Accelerate | Own FFT / Intel IPP |
| Text layout | Core Text | Android `StaticLayout` on `Canvas` | Core Text | DirectWrite |
| Share sheet | `UIActivityViewController` | `Intent.ACTION_SEND` with a `FileProvider` URI | `NSSharingServicePicker` | `DataTransferManager` share |

**Code sharing:** macOS should reuse `EditorKit` directly; only the UI changes. For Android and Windows, port Core by hand, or move Core to Kotlin Multiplatform later. Either way, the contract tests (§15) must pass on every platform.

---

## 2. Time

- **`MediaTime`** is an integer count of **ticks at 60,000 per second** (`Int64`). This rate divides exactly by 24, 25, 30, 48, 50, 60 and 120 fps, so repeated splits never drift.
  - From seconds: `ticks = round(seconds × 60000)`.
  - **Never store seconds as a decimal number in the model.**
- **`MediaTimeRange`** is `{start, duration}`, a half-open range `[start, start+duration)`. `contains(t)` means `start ≤ t < end`. Intersection is empty when `end ≤ start`.
- **Speed:** `divided(by: rate)` and `multiplied(by:)` round to the nearest tick.
- **`snappedToFrame(fps)`:** rounds to a multiple of `60000 / fps` ticks. Audio drags and cuts snap at 30 fps.
- **Display format `timecode`:** `m:ss.f`, so 63.25 s is `1:03.3` (C format `"%d:%04.1f"`).

---

## 3. Data model

All types are value types, and all IDs are UUIDs. The complete field list, with types and defaults, is in `Project.swift`. The sample file shows each field once.

### 3.1 Project (top level)

| Field | Type | Default | Notes |
|---|---|---|---|
| `version` | Int | `1` | Bump only for breaking changes (§4.4) |
| `id`, `name` | UUID, String | | |
| `createdAt`, `modifiedAt` | Date | | See §4.2 encoding |
| `aspectRatio` | `"9:16"`, `"3:4"`, `"1:1"`, `"4:5"`, `"16:9"` | `"9:16"` | |
| `background` | `blur` or `color(RGBA)` | blur | |
| `frameRate` | Int | 30 | |
| `media` | [MediaItem] | | |
| `clips` | [VideoClip] | | The main track, in order |
| `audioClips` | [AudioClip] | | |
| `textOverlays` | [TextOverlay] | | Drawn in array order |
| `captions` | CaptionTrack | | |
| `watermark` | Watermark? | nil | |
| `noiseReduction` | `NoiseReduction`? | nil | Denoise for the whole video (DNS). nil = use each clip's older `noiseReduction` |
| `defaultFit` | `fit`, `fill`, `stretch`? | nil | Canvas fit for new clips |
| `defaultAnchor` | `center`, `top`, `bottom`, `left`, `right`? | nil | |

### 3.2 Key enums (stored as strings)

| Enum | Values |
|---|---|
| `MediaKind` | `video`, `photo`, `audio` |
| `NoiseReduction` | `low`, `medium`, `high` |
| `TransitionKind` | `fade`, `dissolve`, `slideLeft` ("Slide"), `slideUp` ("Push Up"), `zoom`, `wipe`, `blur`, `glitch` |
| `ClipEntrance` | `fade`, `zoomIn`, `zoomOut`, `slideLeft`, `slideRight`, `slideUp`, `slideDown`, `rotate`, `spin`, `pop`, `bounce`, `drop`, `blur`, `swing` |
| `ClipCombo` | `pulse`, `heartbeat`, `shake`, `wobble`, `swing`, `float`, `rock`, `spin` |
| `PhotoMotion` | `none`, `zoomIn`, `zoomOut`, `panLeft`, `panRight`, `panUp`, `panDown`, `kenBurns` |
| `TextAnimation` (older, §8.6.1) | `none`, `fade`, `pop`, `slideUp`, `typewriter`, `bounce` |
| `OverlayAnchor` | `topLeft`, `top`, `topRight`, `left`, `center`, `right`, `bottomLeft`, `bottom`, `bottomRight` |
| `AudioClip.Role` | `music`, `voiceover`, `effect`, `extracted` |
| `CaptionPreset` | `classic`, `karaoke`, `bold` (when reading, `minimal` becomes `classic` and `neon` becomes `karaoke`) |
| `Watermark.Kind` | `text`, `image` |
| `TitleCard.Placement` | `opening`, `closing` |

### 3.3 Rules that matter

- **`VideoClip.timelineDuration`:**
  - For stills (`kind == photo` or `freezeAt != nil`) it's `sourceRange.duration`.
  - Otherwise it's `sourceRange.duration ÷ speed`.
- **`VideoClip.sourceTime(atClipTime t)`:**
  - For a freeze frame it's `freezeAt`.
  - For a photo it's `0`.
  - For a reversed clip it's `sourceRange.end − t×speed`.
  - Otherwise it's `sourceRange.start + t×speed`.
- **`hasAudio` (clip):** the clip isn't a still.
- **`AudioClip.followsVideo`:** `fitsVideo ?? (role == music)`.
- **`AudioClip.resolvedDuckLevel`:** `clamp(duckLevel ?? 0.25, 0, 1)`.
- **Audio sections:**
  - `resolvedSections` are the stored sections clipped to `sourceRange`. If none remain, it's one section covering the whole of `sourceRange`.
  - `playedDuration` is the sum of the sections that aren't deleted.
  - `hasSectionEdits` means more than one section, or any section deleted or with volume ≠ 1.
  - `timelineRange` is `[start, start + playedDuration)`.
- **`CaptionSegment.range`:** from its first word's start to its last word's end. `text` is the words joined with single spaces.
- **`Project.duration`** is the length of the edit: `max(main-track length, end of every voiceover)`.
- **`Project.timelineDuration`** is what the timeline shows: `max(duration, end of every audio clip)`.
- **`Project.isEmptyEdit`:** no clips, audio clips, text overlays or caption segments.

---

## 4. Storage and file format

### 4.1 Folder layout

```
<AppData>/Projects/<project-uuid>/
    project.json        the Project, encoded as in §4.2
    thumbnail.jpg       400 px max, JPEG quality 0.8, first clip's first frame
    Media/              every file the project uses; names are stored in project.json
        <UUID>.<ext>                imported media (always a new unique name)
        rev-<base>.mov              reversed copy of a video (REV-1)
        nr2-<level>-<base>.m4a      noise-reduced audio (DNS-3); older apps wrote nr-<level>-<base>.m4a
        music-<trackid>-<secs>.m4a  generated built-in music
        title-<placement>-<8hex>.png  rendered slide image
        watermark-<8hex>.png        watermark image
    Cache/              temporary files; safe to delete

<AppData>/RecentAudio/                 recent audio tracks (MUS-10), shared by all projects
    recent.json         [{id, name, fileName, duration, usedAt}], newest first, at most 5;
                        duration as MediaTime ticks, usedAt as ISO 8601
    <UUID>.<ext>        the app's own copy of each track
```

- **Saving:** write to a temporary file, then rename over `project.json`, so a crash never leaves a half-written file.
- **Listing:** list the project folders whose names are UUIDs. Skip any `project.json` that fails to read. Sort by `modifiedAt`, newest first.
- **Duplicating:** copy the whole folder, give it a new id, add " Copy" to the name, and set both dates to now.

### 4.2 JSON encoding (must match Swift `Codable` exactly)

`project.sample.json` is the authority. The rules:

| Value | Encoding | Example |
|---|---|---|
| UUID | upper-case string | `"11111111-1111-…"` |
| `MediaTime` | integer ticks | `"start": 60000` (= 1 s) |
| `MediaTimeRange` | object | `{"start": 60000, "duration": 240000}` |
| `Date` | **number of seconds since 2001-01-01 00:00:00 UTC** (Apple reference date) | `800000000` |
| `CGSize` | **two-number array** `[width, height]` | `"naturalSize": [1080, 1920]` |
| `RGBAColor` | `{"r","g","b","a"}` with values 0…1 | |
| Simple enum | its raw string | `"aspectRatio": "9:16"` |
| Enum with no value attached | `{"<case>": {}}` | `"background": {"blur": {}}` |
| Enum with a value attached | `{"<case>": {"_0": <value>}}` | `{"color": {"_0": {"r":0,…}}}` |
| `[NoiseReduction: String]` | object keyed by the raw value | `{"medium": "nr-medium-x.m4a"}` |
| Optional set to nothing | **key left out** | |

**Reading and writing rules (important for interoperability):**

1. **Writers must write every non-optional field**, even when it has its default value. Swift's generated decoder fails if a non-optional key is missing, even when the Swift property has a default.
2. **Readers must ignore unknown keys** and give missing optional keys their defaults.
3. **New fields must be optional** (`T?`, or a custom decoder with a default), so older apps and other platforms can still open the project. Every field added since `version 1` follows this rule, for example `photoMotion`, `animation`, `titleCard`, `noiseReduction`, `duckLevel`, `denoisedFileNames`, `defaultFit` and `watermark`.
4. **Removing an enum case** needs a decoder that maps the old string to a remaining case. `CaptionPreset` is the example.
5. **Key order doesn't matter.** iOS writes them sorted.

### 4.3 Kotlin hint (Android)

Use `kotlinx.serialization` with `ignoreUnknownKeys = true` and `encodeDefaults = true` (required by rule 1).
- `MediaTime` needs a custom serializer that writes a `Long`.
- `CGSize` needs a custom serializer that writes `[w, h]`.
- `Date` needs a custom serializer that converts a `Double` of seconds since 2001 to and from an `Instant` (add or subtract 978307200 s, the gap to the 1970 epoch).
- Enums with values attached need custom serializers that produce the `{"case":{"_0":…}}` shape.

### 4.4 Versioning

`version` stays `1` while changes are additive (rule 3). A breaking change bumps it, and every platform must ship a migration from the previous version before writing the new one.

---

## 5. Edit session, undo and autosave

- **One step per edit:** `apply(label, edit)` copies the project, runs the edit (which may fail), runs `refitMusic()`, then commits. Committing does this:
  1. If nothing changed, do nothing.
  2. Push `(label, previous project)` onto the undo stack, keeping at most `200` entries.
  3. Clear the redo stack and set the new project.
  4. Set `modifiedAt` to now, increase `revision`, and drop the selection if what it pointed at no longer exists.
- **Coalescing:** `applyCoalescing(label, key, edit)` is used for slider drags. If `key` matches the last coalescing key, the project is replaced **without** adding a new undo entry. Undo, redo and any non-coalescing commit reset the key.
  - **Key convention:** `"<what>-<object id>"`, for example `"fi-<clipID>"` for filter intensity, `"duck-<audioID>"`, `"trim-<clipID>-<edge>"`.
- **Failures:** an edit that fails leaves the project unchanged. The UI shows a toast:
  - Too short: "Too close to the clip edge".
  - Anything else: "Couldn't <label in lower case>".
- **Snapshots:** every undo entry is a full `Project` snapshot. The model never contains media bytes, so this is small.
- **Selection** is `none`, `clip(id)`, `text(id)`, `audio(id)` or `captions`.
- **Autosave:** wait `400 ms` after the last change, then save. Also save on editor close, together with the thumbnail. Empty projects are deleted on close (LIB-4).
- **Rebuilds:** the preview rebuild waits `60 ms` after edits so slider drags stay smooth. Trimming rebuilds straight away when the finger lifts.

---

## 6. Editing algorithms (Core)

Constants:
- `minimumClipDuration = 0.1 s`.
- `minimumAudioDuration = 0.2 s`.
- `stillDurationRange` and `textDurationRange` are both `0.5…30 s`.

### 6.1 Timeline layout

The main track is laid out clip after clip, starting with `cursor = 0`. For each clip `i`:
1. `d = timelineDuration`.
2. `overlap = 0`. If there's a next clip and this clip has `transitionOut`, then `overlap = min(transition.duration, floor(min(d, nextD) ÷ 2))`, in ticks.
3. The entry is `range = [cursor, cursor + d)`, `overlapOut = overlap`, `overlapIn = previous overlap`.
4. `cursor += d − overlap`.

The total length is the last entry's end. `entry(at: t)` returns the **last** entry containing `t`, so the incoming clip wins during a transition. At exactly `t == duration` it returns the last entry.

### 6.2 Main-track operations

- **append(media):**
  - Video: `sourceRange = [0, duration)`.
  - Photo: `[0, 3 s)`.
  - Audio: becomes an `AudioClip(role: music)` via `addAudio`.
  - New visual clips take `defaultFit` and `defaultAnchor` when those are set.
- **split(at t):**
  1. Find the entry; `local = t − entry.start`. Fail with *tooShort* if `local < 0.1 s` or `d − local < 0.1 s`.
  2. Start from two copies of the clip. The right copy gets a new id. The left copy's `transitionOut` is set to nil; the right keeps it.
  3. **Stills:** left duration = `local`, right duration = `d − local`.
  4. **Videos:** `sourceLocal = local × speed`.
     - Reversed: the cut point `p = src.end − sourceLocal`; left = `[p, end)` and right = `[start, p)`.
     - Otherwise: `p = src.start + sourceLocal`; left = `[start, p)` and right = `[p, end)`.
  5. Each side keeps only the reframe keyframes inside its new source range.
- **trim(clip, edge, Δ timeline):**
  - **Stills:** a trailing edge adds Δ; a leading edge subtracts it. The result is clamped to `0.1 s … 60 s`.
  - **Videos:**
    - `sourceΔ = Δ × speed` and `minSrc = 0.1 s × speed`.
    - The source start moves when the edge is leading XOR the clip is reversed; otherwise the source end moves.
    - Reversed clips move in the opposite direction.
    - The start is clamped to `[0, end − minSrc]` and the end to `[start + minSrc, media.duration]`.
    - Reframe keyframes outside the new range are dropped.
- **delete:** remove the clip. If it was the last clip, clear the `transitionOut` of the new last clip.
- **duplicate:** insert a copy with a new id right after.
- **move:** after moving, clear the `transitionOut` of the clip that's now last.
- **Movable range (TML-13):** indices `[lo, hi)`, where `lo = 1` if clip 0 is an opening slide (else 0) and `hi = count − 1` if the last clip is a closing slide (else `count`). Slides never move; nothing moves when the range holds fewer than 2 clips.
- **Reorder strip (drag):** tile `52`, gap `6`, pitch `p = 58`. Tile `k` (in the strip's current order) has its left edge at `k × p` from the strip start. The landing slot is `clamp(round((cx − 26) / p), lo, hi − 1)`, where `cx` is the floating tile's centre measured from the strip start; the other clips keep their order and fill the remaining slots. The slot is an index after removing the dragged clip; equal to its old index means no change.
- **Strip placement:** on lift, the strip's start is put so the picked tile is under the finger, then clamped to `[w/2 − stripWidth, w/2]` (`w` = timeline width), the same range auto-scroll keeps it in.
- **setSpeed:** clamped to `0.1…10`. Stills are ignored. Afterwards the overlays are re-timed (below).
- **setSpeedForAllClips(s)** (SPD-4): `s` clamped to `0.1…10` is set on every clip that isn't a still (`kind == photo` or `freezeAt != nil`). Then one re-timing pass runs from the layout before the change. It's one edit (one undo step).
- **Re-timing after a speed change** (SPD-5): keep the old layout `L` and build the new one `L'` (same clip ids, same order). Each old entry `i` *owns* `[Lᵢ.start, Lᵢ₊₁.start)` on the old timeline, and the last one owns `[start, end)`. So during a transition the incoming clip owns the overlap, as in `entry(at:)`. A timeline time `t` maps to `t'`:
  1. `t ≤ 0` → `t`.
  2. `t ≥ L.duration` → `t + (L'.duration − L.duration)`.
  3. Otherwise, with `i` the entry that owns `t`, old duration `d` and new duration `d'`: `t' = L'ᵢ.start + round((t − Lᵢ.start) × d' ÷ d)` in ticks. If there's a next clip, `t' = min(t', L'ᵢ₊₁.start)` (a transition that shrank can't push it past the next clip).

  Clips whose duration didn't change map 1 : 1, and the clips after a change just shift. The map is applied to:
  - **Caption words:** `start` and `end`. Words whose range becomes empty are dropped, then segments left with no words.
  - **Text overlays:** `start` and `end`, then the duration is clamped to `0.5…30 s`, keeping the new start.
  - **Voiceovers and extracted audio:** `start` only; the length doesn't change.
  - Music, effects and everything else stay where they are.

  The slider re-times on every step, so a drag is the same as a chain of these maps.
- **setReversed:** only for video clips that aren't freeze frames.
- **insertFreezeFrame(at t):**
  - The still is a copy with: new id, `freezeAt = sourceTime(local)`, `sourceRange = [freezeAt, freezeAt + 1.5 s)`, no transition, not reversed, `speed = 1`, no reframe.
  - Where it goes:
    - If `local < 0.1 s`, insert it before the clip.
    - If `d − local < 0.1 s`, insert it after the clip.
    - Otherwise, split at `t` and insert it between the two pieces.
- **setStillDuration(d, allPhotos):** clamped to `0.5…30 s`. With `allPhotos`, every `kind == photo` clip is set too. Freeze frames are only changed directly.
- **setContentFit(fit, anchor):** stores `defaultFit` and `defaultAnchor`, then applies them to every clip **except title slides**.
- **setPhotoMotion(m, allPhotos):** `none` is stored as nil.
- **setTransition(t, after clip):** ignored on the last clip.
- **Title slides:**
  - **Insert or update:** reuse the existing slide of that placement (update its media, card and duration, clamped to 0.5–30 s).
  - **New slide:** otherwise create a photo clip with `transform.fit = fill` and `titleCard` set. Insert it at index 0 for an opening slide; append it for a closing slide.
  - **Remove:** delete it, then clear the last clip's transition.
- **rippleDelete(ranges)** (silence removal, engine only):
  1. Clear all transitions and merge the ranges.
  2. For each range, starting from the last: clip it to `[0, total)` and split at its end and its start. Ignore failures. Then delete clips that lie inside the range, leaving less than `0.1 s` outside it.
  3. Shift text ranges, caption words, voiceovers and extracted audio, using `t ≥ cut.end → t − cut.duration`, and `cut.start < t < cut.end → cut.start`.
  4. Drop text shorter than 0.1 s and caption words or segments that end up empty.
- **syncCutsToBeats** (engine only): see `Editing.swift`. Each cut moves to the nearest beat that leaves the clip at least `0.4 s` long, without going past the end of the source.

### 6.3 Text operations

- **addText:**
  - Text "Your text" at the playhead, lasting `3 s`.
  - Animation: entrance `pop`, exit `fade`, `inDuration = outDuration = 0.4`.
  - The older `animationIn` and `animationOut` are both set to `none`.
- **setTextDuration:** clamped to `0.5…30 s`. **moveText:** the start is at least 0.
- **setTextAnchor(nil):** also resets the centre to `(0.5, 0.5)`.
- **duplicateText:** the copy starts at the original's end.

### 6.4 Audio operations

- **addAudio:** puts the clip on lane `0, 1, 2, …`, the first lane where nothing overlaps it.
- **refitMusic()** runs after **every** edit. For each clip where `followsVideo` is true and `hasSectionEdits` is false, it sets `sourceRange.duration = max(0.2 s, media.duration − sourceRange.start)`. So uncut music always runs to the end of the song.
- **splitAudio(at t):**
  1. `local = t − start`. Both pieces must be at least `0.2 s`.
  2. Map `local` to song time, skipping deleted sections.
  3. Both pieces get `fitsVideo = false`.
  4. The left piece is `[src.start, cut)` with `fadeOut = 0`.
  5. The right piece gets a new id, `[cut, src.end)`, `start = t` and `fadeIn = 0`.
- **startAudioHere(id, at t)** (MUS-11, "Start Here"):
  1. `before` = the latest end, at or before the clip's start, among other clips on the same lane, or 0.
  2. `splitAudio(at t)` (so the same `0.2 s` limits apply), then delete the left piece.
  3. The right piece gets `start = before` and `fadeIn = min(0.3 s, playedDuration ÷ 2)`. It keeps its `fadeOut`.
  4. It's one edit (one undo step). The UI then selects the piece, seeks to its start and plays.
- **audioGapStart(id):** the latest end, at or before the clip's start, among other clips on the same lane, or 0 if there are none. If `clip.start − that < 0.2 s`, the answer is nil (no gap).
- **moveAudioToGapStart:** `start = audioGapStart`.
- **repeatAudio(id):**
  1. `L = playedDuration` and `videoEnd = layout.duration`. Stop (0 copies) if `L < 0.2 s` or `end ≥ videoEnd − 0.2 s`.
  2. On the original: keep its `fadeOut` aside, set `fitsVideo = false` and set `fadeOut = 0`.
  3. Add copies while `videoEnd − cursor ≥ 0.2 s`. Each copy has a new id, `start = cursor` and `fadeIn = 0`. Unless the clip has section edits, its duration is `min(L, videoEnd − cursor)`.
  4. The last copy gets the original fade-out.
  5. Each copy goes on the same lane if that's free, otherwise through `addAudio`.
- **duplicateAudio:** placed right after the original on the same lane if free, otherwise via `addAudio`. Both get `fitsVideo = false`. The interface no longer uses it.
- **extractAudio(clip)** (no interface): needs a clip with sound, not reversed, at `speed == 1`. It creates an `extracted` audio clip with the same source range, at the clip's timeline start and volume, and mutes the clip.
- **Sections** (no interface):
  - `addAudioMarker` splits the section containing the time, at least `0.2 s` from its edges.
  - Section volume is clamped to `0…2`.
  - At least one section must stay undeleted.
  - Removing the last marker of a plain clip sets `sections` back to nil.

### 6.5 Caption operations

- **Grouping words into captions:** go through the words in order and start a new caption before a word if any of these is true:
  - The current caption already has `5` words.
  - The span from the caption's first word to this word's end would exceed `2.6 s`.
  - The gap since the last word is over `0.55 s`.
  - The last word ended with `.`, `!` or `?`.
- **Splitting a recognised phrase into words:** when the recogniser returns several words with one time, divide the time between them in proportion to their character counts. Each word lasts at least `0.04 s`.
- **Re-timing edited text:** split the new text on whitespace. Each word gets an equal share of the caption's original range.
- **removeFillers:** see FEATURES CAP-6. To compare, lower-case the word and trim punctuation and whitespace, then look it up in the filler set.
- **Showing a caption at time t** (captions must be visible):
  - The first caption where `start ≤ t < end + 0.25 s`.
  - The active word is the last word whose start is `≤ t`.

---

## 7. Composition (what plays when)

- **Length:** the composition lasts `project.duration`. Audio past that point, such as music longer than the video, is cut off. **Preview only:** the preview composition lasts `max(project.duration, timelineDuration)` (`timelineDuration` = the end of the last audio clip), so music past the video can be heard (`PRV-8`); there's no video there, only the background. The player pauses at `project.duration` unless an audio clip is selected.
- **Main track:** two video lanes (A and B) alternate so clips that overlap during a transition sit on different tracks. For each clip:
  - **Video:** insert `sourceRange` from the media file and time-scale it to `timelineDuration` when `speed ≠ 1`.
  - **Reversed:** use the reversed file, with source range `[media.duration − src.end, + src.duration)`.
  - **Stills:** decode the image once and draw it for the clip's length. Freeze frames take the frame at `freezeAt`.
  - **Smooth slow motion** (`speed < 1`): add the same footage one source frame ahead on a "blend" track. The compositor draws it over the main frame with weight `frac(fileTime × fps)` when that weight is over `0.02`.
- **Clip audio** (on the A/B audio lanes):
  - **When it plays:** only for clips that aren't reversed, aren't muted, have `volume > 0` and whose media has sound.
  - **Source:** the level is `project.noiseReduction ?? clip.noiseReduction` (the clip field only matters for older projects). If there's a level and its cleaned file exists (§9.4), use that file instead.
  - **Speed:** time-scaled like the video. Pitch is kept (spectral time-stretch).
  - **Volume:** `clip.volume`.
  - **At transitions:** ramp `0 → volume` across `overlapIn` and `volume → 0` across `overlapOut`.
- **Audio clips:** each gets its own track. Without section edits, insert `[src.start, src.start + min(src.duration, total − start))`. With section edits, place the kept sections back to back. The volume envelope is in §9.

---

## 8. Rendering (per frame)

The output canvas is `aspectRatio.renderSize(shortEdge)`, with both sides rounded to even numbers.
- If `ratio ≥ 1`: `(even(short × ratio), short)`.
- Otherwise: `(short, even(short ÷ ratio))`.

The preview uses a short edge of `720`. Export uses `720`, `1080` or `2160`.

### 8.1 Draw order

1. Clear to black, or to the canvas colour when `background = color`.
2. **Blurred background** (only when `background = blur`):
   1. Draw the bottom visible clip at a quarter of the canvas size, filling it, with brightness `0.8`.
   2. Gaussian-blur it with sigma `= small width ÷ 18`.
   3. Stretch it over the full canvas.
3. **Clips**, in timeline order: at most two during a transition, outgoing first. Each is one textured quad using the layer shader (§8.3), plus the slow-motion blend quad (§7).
4. **Text overlays**, in array order (§8.6).
5. **Watermark** (§8.8).
6. **Captions**, on top of everything (§8.7).

Output is premultiplied alpha, in sRGB.

### 8.2 Layer geometry (where a clip lands)

Everything is in canvas-normalised coordinates: `(0,0)` is top-left and `(1,1)` is bottom-right.
- **Display size:**
  - `content = naturalSize × (crop.width, crop.height)`, using the upright size.
  - Swap width and height if `quarterTurns` is odd.
- **Mode:**
  - `fill = transform.fit == fill || a reframe is active || forceFill`.
  - `stretch = fit == stretch` (and not filling).
- **Base scale:**
  - `sx = canvasW ÷ contentW` and `sy = canvasH ÷ contentH`.
  - `base = fill ? max(sx, sy) : min(sx, sy)`.
  - `zoom = transform.scale × animation.scale`.
- **Quad size:**
  - Stretch: `canvas × zoom`.
  - Otherwise: `content × base × zoom`.
- **Centre:**
  1. Start at `(0.5, 0.5)`.
  2. **Anchor** (only when not stretched, no reframe, and the anchor isn't `center`): with `dx = (sizeW − canvasW) ÷ canvasW ÷ 2` and `dy` likewise:
     - `left: +dx`, `right: −dx`, `top: +dy`, `bottom: −dy`.
  3. `+= (offsetX, offsetY) × 0.5`.
  4. `+= animation.offset`.
  5. **Reframe:** with keyframe centre `c` (0…1 within the content):
     - `d = (0.5 − c) × size ÷ canvas`.
     - Clamp each axis to `±max(0, size − canvas) ÷ canvas ÷ 2`.
- **Corners:** TL, TR, BL and BR at `centre ± size ÷ canvas ÷ 2`. Rotate by `animation.rotation` (clockwise, radians) **in pixel space** around the centre.
- **Texture coordinates:** for each corner's local position `(0|1, 0|1)`:
  1. Mirror for `flipH` and `flipV`.
  2. Undo `quarterTurns` (`unrotate`).
  3. Map into the crop: `(crop.x + x × crop.w, crop.y + y × crop.h)`.
  4. Undo `sourceQuarterTurns` to address the raw decoded frame.
  - `unrotate` one clockwise turn maps `(x, y) → (y, 1 − x)`.
- **Reframe centre at a source time:** smoothstep between neighbouring keyframes (`s = t²(3 − 2t)`), and hold the first and last values outside them.

### 8.3 Layer shader (colour pipeline)

Port `Shaders.metal` line for line. Per pixel, in this order:

1. **Glitch** (when `glitch > 0.001`): `slice = floor(y ÷ canvasH × 24)` and `n = fract(sin(slice × 91.7 + floor(time × 30) × 13.3) × 43758.5453)`. Then `uv.x += (n − 0.5) × 0.08 × glitch × step(0.6, n)`.
2. **Sample**, with an optional disc blur when `blurRadius ≥ 0.5`: 13 taps, the centre plus `i = 1…12` at radius `√(i ÷ 12) × R` and angle `i × 2.39996323`, all averaged.
3. **Glitch colour split:** `r` sampled at `uv + (0.012 × glitch, 0)` and `b` at `uv − (0.012 × glitch, 0)`.
4. **Sharpen:** `c += (c − mean(4 neighbours)) × sharpen × 1.5`.
5. **Adjust** (`luma = dot(c, (0.2126, 0.7152, 0.0722))`):
   ```
   c *= 2^(exposure × 1.5)
   l = luma(c); hw = smoothstep(0.45, 1, l); sw = 1 − smoothstep(0, 0.55, l)
   c += c × highlights × 0.45 × hw
   c += shadows × 0.35 × sw
   c = (c − 0.5) × (1 + contrast × 0.8) + 0.5
   c = mix(luma(c), c, 1 + saturation)
   c.r += warmth × 0.08;  c.b −= warmth × 0.08
   c = clamp(c, 0, 1)
   ```
6. **Filter look:** a 33³ 3D lookup table built from the look's formula (§8.4), sampled at texel centres: `coord = c × (size − 1) ÷ size + 0.5 ÷ size`, trilinear. Then `c = mix(c, graded, intensity)`.
7. **Vignette:** `v = smoothstep(0.85, 0.2, length(local − 0.5) × 1.2)` and `c *= mix(1, v, vignette)`.
8. **Brightness:** `c *= brightness`, used by fade-through-black. Alpha is `sample.a × opacity`.
9. **Cut-out mask** (person segmentation): `m = smoothstep(0.15, 0.85, mask)`.
   - Mode 1 (transparent / canvas): `alpha *= m`.
   - Mode 2 (blur): `c = mix(blurred × brightness, c, m)`, where `blurred` is the frame blurred with sigma `= width ÷ 60`.
   - Mode 3 (colour): `c = mix(colour, c, m)`.
10. **Wipe:** `alpha *= 1 − smoothstep(p − 0.02, p + 0.02, x ÷ canvasW)`.
11. **Output** premultiplied: `(c × alpha, alpha)`.

### 8.4 Filter looks (exact)

Helpers, all working on RGB values from 0 to 1:
- `luma(c) = dot(c, (0.2126, 0.7152, 0.0722))`
- `saturate(c, a) = luma + (c − luma) × a`
- `contrast(c, a) = (c − 0.5) × a + 0.5`
- `sCurve(x, k) = x + (smoothstep(x) − x) × k`, where `smoothstep(x) = x²(3 − 2x)` and x is clamped to 0…1. `curve` applies `sCurve` per channel.
- `lift(c, b) = c × (1 − b) + b`
- `splitTone(c, sh, hi, a) = c + ((sh × (1 − l) + hi × l) − 0.5) × a`, with `l = luma(c)`

The final result is clamped to 0…1.

| id | Name | Formula |
|---|---|---|
| `vivid` | Vivid | `curve(saturate(c, 1.35), 0.35)` |
| `warm` | Warm | `curve((r×1.08+0.02, g×1.02, b×0.88), 0.15)` |
| `cool` | Cool | `(r×0.9, g, b×1.1+0.03)` |
| `teal_orange` | Cinema | `curve(splitTone(saturate(c,1.1), (0.35,0.55,0.62), (0.68,0.52,0.38), 0.35), 0.3)` |
| `film` | Film | `lift(curve(saturate(c,0.85),0.25),0.06) × (1.02,1,0.95)` |
| `fade` | Fade | `lift(saturate(c,0.8),0.12)` |
| `vintage` | Vintage | `s=saturate(c,0.7); lift((s.r×1.07, s.g×0.98, s.b×0.82),0.08)` |
| `mono` | Mono | `(l,l,l)` |
| `noir` | Noir | `l=sCurve(luma,0.9); v=l²×1.05; (v,v,v)` |
| `sepia` | Sepia | `(l×1.07+0.05, l×0.9+0.03, l×0.7)` |
| `pastel` | Pastel | `lift(saturate(c,0.75),0.1) × (1,0.98,1.02)` |
| `punch` | Punch | `contrast(saturate(c,1.25),1.2)` |
| `golden` | Golden Hour | `curve(splitTone(c,(0.45,0.4,0.5),(0.75,0.55,0.3),0.4),0.2)` |
| `moody` | Moody | `s=saturate(c,0.75); curve(splitTone(s,(0.4,0.5,0.55),(0.55,0.5,0.45),0.3),0.4) × 0.95` |
| `lush` | Lush | `s=saturate(c,1.2); (s.r×0.97, s.g×1.06, s.b×0.98)` |
| `bleach` | Bleach | `curve(c×0.5 + l×0.5, 0.6)` |
| `night` | Night | `(r×0.75, g×0.9, b×1.15+0.02) × 0.9` |
| `rose` | Rose | `(r×1.06+0.02, g×0.96, b+0.02)` |
| `matte` | Matte | `lift(curve(c,0.2),0.09) × 0.96` |
| `chrome` | Chrome | `curve(saturate(c,1.15),0.55)` |

The filter thumbnails in the panel run the same function on the CPU over a 120 px frame.

### 8.5 Animation curves (exact)

`LayerAnimation` holds `opacity` (1), `brightness` (1), `offset` (0; canvas units), `scale` (1), `blurRadius` (0 texels), `wipeProgress` (−1 = off), `glitch` (0) and `rotation` (0, radians clockwise).
**Combining** two animations multiplies scales, opacities and brightnesses; adds offsets and rotations; takes the larger blur and glitch; and lets the second animation's wipe win if it's set.

**Transitions.** `p` is progress from 0 to 1 and `e = smoothstep(p)`. "In" is the incoming clip and "out" the outgoing one.

| Kind | Outgoing | Incoming |
|---|---|---|
| fade (dip to black) | `brightness = max(0, 1 − 2p)` | `opacity = p<0.5 ? 0 : 1`, `brightness = max(0, 2p − 1)` |
| dissolve | none | `opacity = e` |
| slideLeft | `offset.x = −e` | `offset.x = 1 − e` |
| slideUp | `offset.y = −e` | `offset.y = 1 − e` |
| zoom | `scale = 1 + 0.4e` | `scale = 1.4 − 0.4e`, `opacity = e` |
| wipe | none | `wipeProgress = e` |
| blur | `blur = sin(πp) × 24` | the same blur, plus `opacity = e` |
| glitch | `glitch = sin(πp)` | the same glitch, plus `opacity = p<0.5 ? 0 : 1` |

**In / Out** (`entrance(kind, t)`). `e = 1 − (1 − t)³` and `inv = 1 − e`. Out uses the same function with `t` counting down to 0 at the clip's end.

| Kind | Formula |
|---|---|
| fade | `opacity = t` |
| zoomIn | `scale = 0.3 + 0.7e`, `opacity = min(1, 2t)` |
| zoomOut | `scale = 1.6 − 0.6e`, `opacity = min(1, 2t)` |
| slideLeft / Right / Up / Down | `offset = (inv,0) / (−inv,0) / (0,inv) / (0,−inv)` |
| rotate | `rotation = −π/2 × inv`, `scale = 0.6 + 0.4e`, `opacity = min(1, 2t)` |
| spin | `rotation = −2π × inv`, `scale = 0.2 + 0.8e`, `opacity = min(1, 1.5t)` |
| pop | `u = t − 1`; `scale = max(0.01, 1 + 2.9u³ + 1.9u²)`; `opacity = min(1, 3t)` |
| bounce | `scale = max(0.01, bounceOut(t))` |
| drop | `offset.y = −(1 − bounceOut(t))` |
| blur | `blur = inv × 28`, `opacity = min(1, 1.5t)` |
| swing | `rotation = 0.5 × inv × cos(3πt)`, `opacity = min(1, 2t)` |

`bounceOut` is the standard Penner easing (n = 7.5625, d = 2.75).

**Combos.** `s` is the clip-local time in seconds and `w = 2π`.

| Kind | Formula |
|---|---|
| pulse | `scale = 1 + 0.05 × (0.5 − 0.5 cos(w s))` |
| heartbeat | `ph = s mod 1`; `scale = 1 + 0.07 × (e^{−((ph−0.1)/0.05)²} + 0.7 e^{−((ph−0.3)/0.05)²})` |
| shake | `offset = (0.012 sin(7ws) × (0.6 + 0.4 sin(1.3ws)), 0.006 sin(11ws))` |
| wobble | `rotation = 0.06 sin(2ws)` |
| swing | `rotation = 0.1 sin(ws/1.6)` |
| float | `offset.y = 0.02 sin(ws/2.4)` |
| rock | `rotation = 0.05 sin(ws/1.2)`, `scale = 1.04` |
| spin | `rotation = ws/6` |

**Putting a clip's animation together** at local time `L` in a clip of length `D`:
1. Start with the combo.
2. `inLen = min(inDuration, D/2)` and `outLen = min(outDuration, D/2)`.
3. If `L < inLen`, combine `entrance(L / inLen)`.
4. If `L > D − outLen`, combine the exit, `entrance((D − L) / outLen)`.
5. The transition animation is combined last.
6. **Photo motion**, applied while playing. `e = smoothstep(progress)` and `pan = 0.06`:
   - zoomIn: `scale = 1 + 0.25e`. zoomOut: `scale = 1.25 − 0.25e`.
   - pans: `scale = 1.18`, and the offset moves from `+pan` to `−pan` (panLeft and panUp) or from `−pan` to `+pan` (panRight and panDown).
   - kenBurns: `scale = 1.08 + 0.2e`, `offset = (−0.035 + 0.07e, 0.025 − 0.05e)`.

**Preview play speed** (PRV-9): the preview player's playback rate (on iOS, `AVPlayer.defaultRate`; picked while playing, the player is paused and restarted at the new rate with `playImmediately(atRate:)`, so it switches at once and keeps playing) is one of `0.5, 0.75, 1, 1.25, 1.5, 2`. The player item keeps pitch (spectral time-pitch). Editor state only: not in `Project`, not an undo step, never passed to export.

**Animations only while playing** (PRV-3): In/Out/Combo, photo motion and text animation are skipped unless the player is playing or exporting. Transitions always apply.

### 8.6 Text overlays

- **Drawing the text:**
  - Font size = `canvasH × style.size`. Outline width = `fontSize × style.outlineWidth`.
  - Maximum width = `0.9 × canvasW`. Lines are centred.
  - Padding = `ceil(fontSize × 0.35 + outlineWidth × 2)` on every side.
  - **Label background:** a rounded rectangle, inset `(−0.3 × fontSize, −0.12 × fontSize)`, with corner radius `0.25 × fontSize`.
  - **Shadow:** offset `(0, 0.06 × fontSize)` downwards, blur `0.18 × fontSize`, black at 65%.
  - **Outline:** a stroke drawn beneath the fill, with round joins.
- **Position:**
  - **Fixed spot:** the centre is placed so the text's box keeps a margin `m = 0.04` (in canvas-width units; the vertical margin is `m × W/H`) from the edges at that spot. For each axis, −1 means `m + half-size`, 0 means `0.5`, and +1 means `1 − m − half-size`.
  - **Free position:** `(centerX, centerY)`.
  - While being dragged, a live override position is drawn without rebuilding (§13).
- **Animation:**
  - If `animation` is set, use §8.5 on the overlay's range: offset, scale, rotation and opacity.
  - Otherwise, use the older `animationIn` and `animationOut` (§8.6.1).
- **Fonts (cross-platform risk):** iOS stores **PostScript font names**. Map them to the nearest bundled fonts on other platforms, and keep the mapping identical across those platforms. Bundling open-licence fonts for all platforms (including iOS) is the recommended next step.

| UI name | iOS font name | Suggested open font |
|---|---|---|
| Bold | `HelveticaNeue-Bold` | Inter Bold |
| Classic | `Georgia-Bold` | Merriweather Bold |
| Rounded | `ArialRoundedMTBold` | Nunito ExtraBold |
| Condensed | `Futura-CondensedExtraBold` | Oswald Bold |
| Elegant | `Didot-Bold` | Playfair Display Bold |
| Mono | `Menlo-Bold` | JetBrains Mono Bold |
| Script | `SnellRoundhand-Black` | Great Vibes |
| Heavy | `AvenirNext-Heavy` | Nunito Sans Black |

#### 8.6.1 Older text animations

These are used only when `animation` isn't set. `d = min(0.4, range.duration / 3)`.
- **fade:** `opacity *= p`.
- **pop:** `scale *= 1 + 2.70158 (p−1)³ + 1.70158 (p−1)²`, and `opacity *= min(1, 2p)`.
- **slideUp:** `offsetY += (1 − smoothstep(p)) × 0.06`, and `opacity *= p`.
- **typewriter:** on the way in, show `ceil(count × p)` characters. On the way out, fade.
- **bounce:** `offsetY −= |sin(2.5πp)| × (1 − p) × 0.04`, and `opacity *= min(1, 3p)`.

### 8.7 Captions

- **Styles.** `H` is the canvas height and the maximum width is `0.86 W`.

| Preset | Font | Size | Look | Words |
|---|---|---|---|---|
| classic | HelveticaNeue-Medium | `0.036 H` | no shadow, black box at 60% | all white |
| karaoke | HelveticaNeue-Bold | `0.042 H` | black outline `0.004 H`, shadow | active word in the highlight colour, others white |
| bold | Futura-CondensedExtraBold | `0.055 H` | black outline `0.006 H`, shadow, **upper case** | the same as karaoke |

- **Placement:** centred at `(0.5, positionY)`.
- **Pop:** in karaoke and bold, a newly active word scales the whole caption by `1 + 0.04 × (1 − since ÷ 0.12)` for its first `0.12 s`.

### 8.8 Watermark

- **Text:**
  - Font: HelveticaNeue-Bold at `canvasH × 0.12 × size`, maximum width `0.9 W`, with shadow.
  - Colour: `color`.
- **Image:** scaled so its width is `canvasW × size`.
- **Position:** the anchor with margin `0.035`. Opacity: `opacity`.

### 8.9 Title slides

- **Canvas:** a 2160×2160 PNG with the `background` colour.
- **Glow** (when `gradient` is on):
  - A radial accent glow, from 45% opacity to 0, centred at `(0.5, 0.55)`, radius `0.55`.
  - An edge vignette, black from 0 to 35%, radius `0.35 → 0.75`.
- **Text:**
  - The title is HelveticaNeue-Bold at `0.075 × side`.
  - The subtitle is HelveticaNeue-Medium at `0.034 × side`, using the text colour at 75% opacity.
  - Text width is at most `0.48 × side` (the safe area).
- **Layout:** centred vertically, as title, gap `0.03`, accent bar (`0.07 × side` wide, `0.008` high), gap, then subtitle.
- **On the timeline:** the clip is always drawn with Fill, so any canvas ratio crops only empty margins.
- **Presets** (background / accent / text colour / gradient):

| Preset | Background | Accent | Text | Gradient |
|---|---|---|---|---|
| midnight | (0.08, 0.08, 0.10) | (1, 0.24, 0.38) | white | yes |
| sunset | (0.55, 0.12, 0.22) | (1, 0.6, 0.2) | white | yes |
| ocean | (0.04, 0.12, 0.28) | (0.2, 0.85, 0.85) | white | yes |
| forest | (0.06, 0.2, 0.12) | (0.6, 0.9, 0.4) | white | yes |
| grape | (0.2, 0.08, 0.35) | (0.85, 0.5, 1) | white | yes |
| paper | (0.96, 0.95, 0.92) | (1, 0.24, 0.38) | (0.1, 0.1, 0.12) | no |
| noir | black | white | white | no |

---

## 9. Audio

### 9.1 Clip sound

See §7. The volume crossfades across transitions.

### 9.2 Audio clip envelope (without section edits)

`vol = clip.volume`. `start` and `end` are where the clip plays on the timeline, and `ramp = 0.2 s`.
1. Set the volume to `vol` from 0.
2. **Fade in:** ramp `0 → vol` over `[start, start + min(fadeIn, length))`.
3. **Ducking**, when `autoDuck` is on. For each speech range (§9.3) intersected with `[start + fadeIn, end − fadeOut]`, and longer than `2 × ramp`:
   - ramp `vol → vol × duckLevel` over the first `ramp`,
   - hold that level,
   - then ramp back to `vol` over the last `ramp`.
4. **Fade out:** ramp `vol → 0` over the last `min(fadeOut, length)`.

**With section edits:** each kept section plays at `clip.volume × section.volume`, with the fade-in only on the first section and the fade-out only on the last.

### 9.3 Where speech is (for ducking)

Each caption segment's range, widened to `[start − 0.15 s, end + 0.25 s]`, with overlapping ranges merged. **Without captions there's no ducking** (the Duck panel says so).

**Muted clips don't duck** (`CLP-5`). Remove from those ranges the timeline range of every main-track clip whose voice is off (`isMuted`), except where something else speaks there: a voiceover or extracted audio clip, or another main-track clip whose sound plays (not muted, not reversed, `volume > 0`, media has sound), such as during a transition overlap. In other words: `speech − (muted − voiced)`.

### 9.4 Noise reduction (DNS), spectral gating

Ports must produce comparable results. The settings:
- **Input:**
  - Decode the clip's audio track to Float32 at **48 kHz**, with the source's channels capped at 2.
  - Note the presentation time of the first sample (`offset`).
- **STFT:** frame `N = 2048`, hop `512` (75% overlap), periodic Hann window (peak 1). Pad `N` zeros at the start and `N + hop` at the end.
- **Noise fingerprint:**
  - Mix to mono, which is the average of the channels.
  - Compute each frame's energy, `Σ x²` over the frame.
  - **Candidate frames:** only frames that lie fully inside the real audio (none of the padding), and that aren't digitally silent (energy > `N × 10⁻¹⁰`, about −100 dBFS).
  - **Noise floor:** group the candidates by second (`frame index ÷ 93`, integer division; 93 = 48000 / hop rounded down, and frame indices count from the start of the padded signal), take each second's lowest energy, and take the median of those (`sorted[count / 2]`). Drop candidates whose energy is below `floor × 0.1` (more than 10 dB under it). If fewer than 5 remain, keep all candidates. If there are no candidates, use every frame.
  - Take the **quietest 10%** of what remains (at least 5) and average their magnitude spectra. That gives `noise[k]` for bins `0…N/2`.
  - Why: a quiet lead-in, a fade-in, a muted moment or the padding is quieter than the real noise. If it fills the quietest 10%, the fingerprint drops to near zero and nothing is removed. Older apps had this bug, which is why their files are made again (below). The per-second median ignores stretches like that unless they last most of the clip.
- **Gain per frame and bin**, from the mono magnitude `m`:
  ```
  g = clamp(1 − α × noise[k] / m, floor, 1)     (g = 0 → floor when m = 0)
  g = (g ≥ prev[k]) ? g : prev[k] × 0.6 + g × 0.4   // instant attack, slow release
  smoothed[k] = (g[k−1] + 2g[k] + g[k+1]) / 4       // for k in 1…N/2−1
  ```

  | Level | α (over-subtraction) | floor |
  |---|---|---|
  | low | 1.5 | 0.30 |
  | medium | 2.2 | 0.15 |
  | high | 3.0 | 0.06 |

- **Apply:** the same gains go on every channel's spectrum. Inverse FFT, multiply by the synthesis Hann window, overlap-add. Scale by `1 ÷ (2N × 1.5)`. (iOS's `vDSP_fft_zrip` forward-then-inverse round trip scales by 2N; Hann² at 75% overlap sums to 1.5. Adjust the factor to your FFT library's scaling.)
- **Output:**
  - Trim off the padding.
  - Add `round(offset × 48000)` samples of silence at the start, so timing matches the original file.
  - Clamp to ±1 and write **lossless** audio: Apple Lossless `.m4a` on iOS; FLAC or WAV elsewhere. Avoid AAC, whose start-up delay shifts the timing.
- **What gets cleaned:** every media item used by a main-track video clip (not a photo or freeze frame) that has sound. Items are processed one after another; progress is `(items done + this item's progress) ÷ items`.
- **Recording it:** in one undo step, store each file name (`nr2-<level>-<base>.m4a`) in `media.denoisedFileNames[level]`, set `project.noiseReduction = level`, and clear `noiseReduction` on every clip. Off sets `project.noiseReduction = nil` and also clears every clip's value. If a file is missing, play the original audio.
- **Media added later:** while `project.noiseReduction` is set, cleaning runs for newly added videos as soon as they're added, and records their file names in its own undo step.
- **Reuse:** picking a level reuses the recorded file only if it exists and its name starts with `nr2-`. A file from the older fingerprint rule (`nr-…`) is made again. Until then, playback keeps using whatever file is recorded.
- **Required results** (test signal: hiss at `0.03` amplitude, and a 300 Hz tone at `0.3` amplitude that's on every other 0.5 s):
  - The hiss drops by **more than 8 dB** at every level.
  - The tone changes by **less than 1.5 dB**.
  - Low < Medium < High in how much hiss they remove.
  - The cleaned tone starts within **20 ms** of its original start.
  - With **0.5 s of silence and then 0.5 s of the signal at 0.1×** placed before it, the hiss still drops by more than 8 dB and the tone changes by less than 1.5 dB at every level.

### 9.5 Waveforms

Decode to mono at 8 kHz, then split into `400` buckets of peak absolute values, normalised to 0…1.

---

## 10. On-device AI

All AI must run fully on the device and work with no network.

### 10.1 Captions (CAP-1)

1. **Mix the speech:** build the composition **without** music or effect audio clips. Mix it down to **16 kHz mono** PCM in timeline time. Stop with a time-out after 60 s.
2. **Transcribe on the device**, with English (US) as the default language. Stop with a time-out after 90 s.
   - On iOS: `SpeechAnalyzer`, falling back to `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`.
   - **Never** use server recognition.
3. **Build the words**, splitting phrases that share one time as in §6.5.
4. **Group them into captions** (§6.5). Set `isVisible = true` and keep the existing style settings.
5. **Errors:** no speech, recogniser not available, permission refused, or a step timed out. FEATURES CAP-1 has the messages.

### 10.2 Auto Enhance (ENH-1)

1. **Measure:** scale each frame to 64×64 sRGB. Measure:
   - `meanLuma` and `lumaStdDev`, using Rec. 709 luma.
   - `meanSaturation`, the average of `(max − min) ÷ max` per pixel.
   - `redBlueBalance`, the average of `r − b`.
   - `shadowsP10`, the 10th-percentile luma.
2. **Frames:** for a photo, the photo itself, scaled so its longer side is 512 px. For a video, 3 frames at 20%, 50% and 80% of the clip. Average the measurements.
3. **Corrections**, each clamped to the range shown:

| Setting | Formula | Range |
|---|---|---|
| exposure | `(0.48 − meanLuma) × 1.4` | −0.5…0.6 |
| contrast | `(0.22 − lumaStdDev) × 2.0` | −0.25…0.35 |
| saturation | `(0.38 − meanSaturation) × 0.9` | −0.2…0.3 |
| warmth | `−redBlueBalance × 1.2` | −0.3…0.3 |
| shadows | `(0.08 − shadowsP10) × 2.5` | −0.1…0.3 |
| highlights | `meanLuma > 0.62 ? −0.25 : 0` | |

The result replaces the clip's adjustments.

### 10.3 Auto Reframe (RFR-1)

1. **Sample frames:** `max(2, floor(duration × 4))` evenly spaced frames across the source range, upright, with the longer side at most 512 px.
2. **Find the subject in each frame:**
   - If there are faces, use the centre of all face boxes, weighted by each box's area.
   - Otherwise, use the most noticeable object, the one with the highest `confidence × area`.
   - Otherwise, nothing.
   - Positions are 0…1 with the origin at the top-left.
3. **Smooth the path:**
   - Start `current` at the first target found, or the centre.
   - For each sample: if there's a target and `|target − current| > 0.04`, then `current += (target − current) × 0.35`.
   - Write a keyframe at every sample.
4. **Store it:** set `clip.reframe` to these keyframes, in source time, and `transform.fit = fill`.

### 10.4 Person segmentation (CUT)

Run it per frame, keeping the segmentation state per clip so the mask is steady from frame to frame. Use a faster mode in the preview and the most accurate mode for export. The output is a grayscale mask, with 1 where the person is. The compositor softens its edge with `smoothstep(0.15, 0.85)`.

### 10.5 Beat detection (engine only)

Used by beat sync. The settings:
- Audio at 11,025 Hz, FFT 1024, hop 128.
- **Onsets:** log-magnitude spectral flux, with bins below 200 Hz weighted ×12. Subtract a local mean over ±16 frames and keep only positive values.
- **Tempo:** a comb search over 60–180 BPM in steps of 0.25, with a log-Gaussian preference centred on 120 BPM. The result is folded into 80–160 BPM.
- **Beats:** placed on that grid, each snapped to the strongest nearby onset.

### 10.6 Silence detection (engine only)

- **Measure:** loudness in dBFS over 20 ms windows of the speech mix.
- **Threshold:**
  - The noise floor is the 10th percentile and the speech level the 90th percentile.
  - If they're less than 12 dB apart, there's nothing to cut.
  - The threshold is 30% of the way from the floor to the speech level.
- **Cutting:** quiet stretches of at least `0.6 s` are removed, keeping `0.12 s` of padding at each side. There's no padding at the very start or end.

---

## 11. Export

- **Size:** `aspectRatio.renderSize(shortEdge: 720 | 1080 | 2160)`, rendered with export quality (the most accurate segmentation).
- **Encoder:** hardware HEVC or H.264 at the "highest quality" preset, MP4 container, AAC audio. The size estimate assumes `256 kbps` audio. The frame rate is set on the composition.
- **Estimated size** (shown before export):
  ```
  base = 720p: 8 Mb/s | 1080p: 16 Mb/s | 4K: 45 Mb/s
  fps factor = ≥60 → 1.5, ≤24 → 0.85, else 1.0
  codec factor = HEVC 0.55, H.264 1.0
  bytes = (base × fps × codec + 256 000) × seconds ÷ 8
  ```
  On platforms where you set the bitrate yourself, aim for `base × fps × codec` so file sizes match.
- **File name:** `<project name>.mp4`.
  - Remove `/ \ : ? % * | " < >` and trim whitespace. If the result is empty, use "Cut & Weld Video".
  - Write it into a new folder per export inside the temporary directory, so the name never clashes.
- **Share:** pass the file's URL to the system share sheet. On Android, use a `FileProvider` content URI with `video/mp4`.

---

## 12. Import

- **Images:** read the pixel size, taking the orientation tag into account. They're decoded upright when shown, with the longer side capped at 2160 px for rendering.
- **Videos:**
  - Read the video track's natural size, its rotation transform, its frame rate (30 if unknown), its duration and whether it has an audio track.
  - **Rotation:** convert it to `sourceQuarterTurns` (clockwise 90° steps). Store `naturalSize` as the **upright** size, with width and height swapped for odd turns.
  - A container with no video track is imported as audio.
- **Audio:** duration and display name.
- **Storage:** the file is copied to `Media/<new UUID>.<extension in lower case>`, with `mov` if there's no extension. The display name is the original file name without its extension.
- **Clean-up:** if reading the file fails, delete the copy and report an error.

---

## 13. UI implementation notes

- **Panels:** opening a panel replaces the toolbar. ✓ closes it, and so does a swipe down (`EDT-1`). Deselecting closes any panel except Canvas, Music and Captions.
  - **Swipe down:** measure the drag in **screen** coordinates. The panel is offset by the drag, so a drag measured in the panel's own coordinates cancels itself out and never reaches the threshold (this was a real iOS bug). Close at `> 30 pt`, or a predicted end `> 80 pt`, and only when the drag is mostly vertical (`dy > |dx|`).
- **Toolbar visibility:** with no content (`Project.duration == 0`), the main toolbar shows only Intro and Outro, and Export is hidden. Captions also needs a video clip (`Project.hasVideoClips`: a clip with `kind == video` that isn't a still). Undo and Redo show only when they can act.
- **Clean frame (PRV-4):**
  - `restStart = overlapIn`, raised to `min(inDuration, D/2)` if the clip has an In animation.
  - `restEnd = D − overlapOut`, lowered to `D − min(outDuration, D/2)` if it has an Out animation.
  - Seek to the midpoint, unless the playhead is already in `[restStart, max(restStart, restEnd)]`.
- **Trimming from the timeline:** when the drag starts, keep a copy of the project. On every move, apply `trim` with the **total** drag distance to that copy, and coalesce it under the key `trim-<id>-<edge>`. Seek to the edge being dragged; for the trailing edge, `0.03 s` before it.
- **Dragging text:** while the finger is down, draw the text at a live override position without rebuilding the preview. On release, commit `anchor = nil` and the new centre, then drop the override about `400 ms` later.
- **Caption editor (CAP-5):** keep a local draft `[segmentId: text]`. Commit only the segments that changed, as one undo step labelled "Edit captions". Focus the starting caption about `450 ms` after the full-screen view opens, so the keyboard comes up with it.
- **Busy work:** pause playback, show the overlay, and report progress (0…1) when it's known. Errors become toasts.
- **Toasts:** last `2.2 s` (6 s in UI tests). A new toast replaces the current one.
- **Layouts (LAY-1…3):**
  - **Choosing:** `wide = horizontalSizeClass == .regular && windowWidth >= 840`. iOS reads the size class from the environment and the width from a `GeometryReader` around the editor. Android uses `WindowSizeClass` (Expanded, which starts at 840 dp).
  - **One editor model, two views:** both layouts show the same `EditorModel` state (selection, `panel`, playhead, playback). Switching layout only changes which views are shown, so nothing is rebuilt.
  - **Sidebar width:** `clamp(0.3 × width, 340, 420)`. Wide timeline height: `min(320, 170 + lanes × 38)`; the phone uses `min(250, 150 + lanes × 34)`.
  - **Tool grid:** the same tool list as the toolbar, laid out in 3 flexible columns. Keep one source of truth for the tools, so the two layouts can't drift apart.
  - **Panels in the sidebar:** the panel container gets a "sidebar" flag (an environment value on iOS). With it, the grabber is hidden and the swipe-down gesture isn't attached.
- **Keyboard shortcuts (LAY-5):**
  - On iOS, these are buttons with `.keyboardShortcut`. Space, the arrows and Delete are disabled while a text panel or the caption editor is open, because those keys belong to the text field there.
  - A frame step is a seek to `currentTime ± 1/30 s`. The playback pauses first.
  - On Android, handle `onPreviewKeyEvent` at the editor's root, with the same keys and the same rule about text fields.
- **Orientation (LAY-4):** iOS sets `UISupportedInterfaceOrientations~iphone` to portrait and `UISupportedInterfaceOrientations~ipad` to all four. On Android, set `screenOrientation` to portrait only on phones (smallest width under 600 dp) and leave it unspecified on tablets.
- **UI-test identifiers:** keep the same accessibility identifiers on every platform, so test scripts can be shared:
  - Wide layout: the sidebar is `editor.sidebar`, its heading `sidebar.title`. The tool tiles keep the toolbar's `tool.<Title>` identifiers.
  - Tool buttons: `tool.<Title>`. Option chips: `chip.<Title>`. Swatches: `swatch.<n>`.
  - Panel close: `panel.done`. Timeline items: `clip.<n>`, `audio.<n>`, `caption.<n>`.
  - Editor: `editor.export`, `editor.close`, `editor.undo`, `editor.redo`, `editor.aspect`, `timeline.add`, `panel.<Title>`, `panel.done`.
  - Export: `export.start`, `export.startShare`, `export.share`, `export.save`, `export.done`.
  - Caption editor: `captionEditor.done`, `captionEditor.cancel`, `caption.field.<n>`, `caption.time.<n>`.
  - Animations: `anim.<In|Out>.<kind>`, `anim.combo.<kind>`, `motion.<kind>`.
  - Preview: `preview` (the video surface), `preview.addMedia` (empty state, `PRV-7`), `preview.pastEnd` (music only, `PRV-8`), `preview.rate` (play speed button, `PRV-9`), `rate.<speed>` (its round buttons, e.g. `rate.0.5×`, `rate.2×`), `toast`, `busy`.
  - Music panel: `music.source.files` (Audio Tracks), `music.source.video` (From Video), `music.recent.<n>` (`MUS-10`), `music.use.<trackId>` (test-only sample tracks).
  - Other: `filter.<id>`, `projects.new`, `project.card`, `mix.*`, `duck.needsCaptions`.

---

## 14. Built-in music

**Not offered to users** (MUS-1). The Music panel lists them only when the app is launched with `-sampleMedia` or `-demoMedia` (UI tests and demos, which can't drive the Files picker). Other platforms only need to **play** them when a project contains them, which works because the generated file is stored in the project.

The four tracks (`sunrise`, `night`, `chill`, `epic`) are **generated on the device** for the length needed: `max(edit length, 10 s)`. They're written as `music-<id>-<seconds>.m4a`. Because the generated file is stored in the project, a project opened on another platform plays exactly the same audio. A port must reproduce the track names, tempos and moods. It may generate different notes, but should keep the same feel: the root note frequency and major or minor key are in `SampleMedia.Track`.

---

## 15. Testing and parity

### 15.1 Contract tests (every platform must pass)

1. **Project file:** read `docs/spec/project.sample.json` and check every field against the expected values listed in `ProjectFileContractTests.sample()`. Write it back out, read it again, and check nothing changed. On iOS, this test re-creates the file if it's missing; commit the file whenever you change the model on purpose.
2. **Editing algorithms:** port the iOS `EditorKit` test suites (`Tests/EditorKitTests/*.swift`). They're small, fixed-input tests: layout and transitions, split and trim (including reversed clips), freeze frame, ripple delete, beat sync, audio split (also of sectioned clips), Start Here, repeat, gap and full-length refit, timeline vs edit length, ducking over muted clips, `hasVideoClips`, recent audio tracks, captions grouping and fillers, older-project loading. Keep the test names, prefixed with the feature ID.
3. **Exact maths:** for each filter, transition, entrance, combo and adjustment, check sample inputs against values computed from the formulas in §8. Generate a golden JSON table from the iOS code once, then check it on every platform.
4. **Noise reduction:** the four checks in §9.4.

### 15.2 UI tests

Port `Tests/CutlineUITests/FeatureUITests.swift` scenario by scenario, using the shared identifiers (§13). Test hooks, passed as launch arguments:
- `-resetLibrary`: start with an empty library.
- `-sampleMedia`: offer "Sample Clips", three generated 4 s clips with tone audio.
- `-sampleCaptions`: give the sample project 4 captions containing fillers.
- `-demoMedia <folder>`: import real demo clips instead.

### 15.3 Changing a feature (process)

1. Update **FEATURES.md**: behaviour, ID, defaults, toasts and the parity table. Record removals under *Decisions*.
2. Update **IMPLEMENTATION.md** if any algorithm, number or format changes.
3. If the model changed: add the field as **optional** (§4.2 rule 3). Update `ProjectFileContractTests.sample()` and regenerate `project.sample.json` by deleting it and running the test.
4. Implement it on iOS with tests, then port it to the other platforms against the same tests.

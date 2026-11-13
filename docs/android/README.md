# Cutline for Android: kick-start guide

How to start the Android app so it behaves exactly like the iOS app. This guide is a **starting plan**. It doesn't replace the spec. When anything here disagrees with the spec, the spec wins:

- [docs/spec/FEATURES.md](../spec/FEATURES.md): what the user sees, with an ID for every feature (`MUS-11`, `PRV-8`, …).
- [docs/spec/IMPLEMENTATION.md](../spec/IMPLEMENTATION.md): exact algorithms, numbers, formulas and the file format.
- [docs/spec/project.sample.json](../spec/project.sample.json): the shared project file. Android must read and write it.
- [AGENTS.md](../../AGENTS.md): the rules for people and AI agents. The short version: the spec decides, removed features stay removed, model changes are additive, everything stays on the device, and feature IDs go in test names and PR titles.

The iOS app in this repo is the **reference implementation**. When the spec is unclear, read the iOS code (file map: IMPLEMENTATION §1.2), then fix the spec so the next person doesn't have to.

---

## 1. Ground rules for the port

1. **Same behaviour, native look.** Use Material 3 and Android conventions for chrome: system back, the Photo Picker, the share sheet. Keep the **order, names and behaviour** of every tool, panel and toast from FEATURES.md.
2. **Same file format.** A project saved on iOS must open on Android and the other way round (IMPLEMENTATION §4). This is checked by a contract test (§5 below).
3. **Same numbers.** Ticks at 60 000 per second, `0.2 s` minimum audio pieces, `30 pt` swipe threshold, `0.3 s` Start Here fade-in, and so on. Copy them, don't re-derive them. Convert `pt` to `dp` one to one.
4. **On the device only.** No network calls, no cloud AI, no analytics SDKs. Libraries must run fully offline (IMPLEMENTATION §1.3).
5. **Record every difference** in the parity table in FEATURES.md, with the reason.

---

## 2. Suggested stack

These are recommendations. Confirm current versions and API levels when you start, because they move faster than this document.

| Concern | Suggestion | Notes |
|---|---|---|
| Language and UI | Kotlin, Jetpack Compose, Material 3 | The timeline can be a Compose `Canvas` or a custom `View`. It must scroll smoothly with a centre playhead (`TML-*`). |
| Architecture | One `EditorViewModel`, the same role as iOS `EditorModel` | The UI never changes `Project` directly; it calls the edit session (IMPLEMENTATION §5). |
| Model and JSON | Pure Kotlin + `kotlinx.serialization` | Custom serializers are needed for `MediaTime`, `CGSize`, `Date` and enums with values (IMPLEMENTATION §4.3). |
| Preview playback | Media3 (ExoPlayer, and the composition preview player when it suits) | The preview must run past the video while music is selected (`PRV-8`). |
| Compositor | OpenGL ES 3 shaders (Media3 `GlEffect`, or your own GL pipeline) | Port the Metal shaders and the maths in IMPLEMENTATION §8 exactly. |
| Export | Media3 Transformer (or `MediaCodec` + `MediaMuxer`) | HEVC when the device supports it, else H.264. MP4 with AAC. Bitrates from IMPLEMENTATION §11. |
| Audio mixing | Media3 audio processors | Volume envelopes, fades and ducking (IMPLEMENTATION §9). |
| Speech to text | Android on-device recognizer, or bundled whisper.cpp | It must never fall back to a server (`CAP-*`, IMPLEMENTATION §10.1). |
| Faces, saliency, segmentation | Bundled ML Kit / MediaPipe models | Offline only (IMPLEMENTATION §10). |
| Pickers | Photo Picker (`PickMultipleVisualMedia(20)`) for media, `OpenDocument("audio/*")` for Audio Tracks | `LIB-1`, `IMP-1`, `MUS-1`. |
| Share | `Intent.ACTION_SEND` with a `FileProvider` URI, `video/mp4` | `EXP-*`. |

**Module layout** (suggested):

```
android/                 (or a separate repository)
  core/          pure Kotlin/JVM: MediaTime, Project, edits, layout, undo, storage  ← port first
  engine/        Media3 + GL: composition, compositor, text raster, import, export
  intelligence/  captions, enhance, reframe, segmentation, noise reduction
  app/           Compose UI: library, editor, panels, timeline, export
```

Keep `core` free of Android imports so its tests run on the JVM in seconds. It could later become Kotlin Multiplatform and be shared with Windows (IMPLEMENTATION §1.3).

---

## 3. iOS → Android map

| iOS (reference) | Android module | What to watch |
|---|---|---|
| `EditorKit/Model/MediaTime.swift` | `core` | `Long` ticks at 60 000/s. Never store seconds in the model. Snap audio cuts at 30 fps. |
| `EditorKit/Model/Project.swift` | `core` | Optional fields stay optional; write every non-optional field (§4.2 rules 1–3). |
| `EditorKit/Model/Editing.swift` | `core` | Pure functions `Project → Project`. `refitMusic()` runs after **every** edit. |
| `EditorKit/Model/TimelineLayout.swift` | `core` | `duration` (the edit) and `timelineDuration` (with music past the video) are different on purpose. |
| `EditorKit/Model/EditSession.swift` | `core` | 200 undo steps, coalescing keys, selection repair. |
| `EditorKit/Model/ProjectStore.swift` | `core` + `app` | Folder layout §4.1, atomic writes, empty projects deleted (`LIB-4`). |
| `EditorKit/Model/RecentAudioStore.swift` | `core` + `app` | 5 entries, own file copies, `recent.json` with **ISO 8601** dates (not the 2001 reference date used in `project.json`). |
| `EditorKit/Engine/CompositionBuilder.swift` | `engine` | Export length `duration`; preview length `max(duration, timelineDuration)`. |
| `EditorKit/Engine/VideoCompositor.swift`, `MetalRenderer.swift`, `Shaders.metal`, `LayerGeometry.swift` | `engine` | Exact geometry, colour pipeline and animation curves (§8). |
| `EditorKit/Engine/FilterLibrary.swift` | `engine` | 3D lookup tables generated from formulas (§8.4). |
| `EditorKit/Engine/TextRasterizer.swift` | `engine` | `StaticLayout` on `Canvas`; fonts in §8.6. |
| `EditorKit/Engine/Exporter.swift` | `engine` | Size estimate formula and file naming (§11). |
| `EditorKit/Engine/MediaImporter.swift` | `engine` | Rotation becomes `sourceQuarterTurns`; `naturalSize` is upright (§12). |
| `EditorKit/Intelligence/*` | `intelligence` | Plain data out; the UI applies it as one edit. |
| `App/Editor/EditorModel.swift` | `app` (ViewModel) | Playback rules, toasts, busy overlay, recent tracks. |
| `App/Editor/EditorView.swift` | `app` | Toolbar contents and visibility rules (`TBR-*`). |
| `App/Editor/Panels.swift` | `app` | Bottom panels, swipe down to close (`EDT-1`). |
| `App/Editor/TimelineView.swift` | `app` | Lanes, trim handles, press-and-hold to move audio, dimmed music past the video. |
| `App/Editor/PreviewView.swift` | `app` | Empty state (`PRV-7`), "Music only · not in export" overlay (`PRV-8`). |
| `App/ProjectsView.swift` | `app` | New Project opens the Photo Picker straight away (`LIB-1`). |

---

## 4. Milestones

Each milestone ends with its tests passing and the parity table updated. Feature IDs are from FEATURES.md.

| # | Milestone | Feature IDs | Done when |
|---|---|---|---|
| M0 | Project skeleton, CI, the **project file contract test** | §4 | `project.sample.json` reads, round-trips and matches the expected values. |
| M1 | `core` port with the iOS unit tests | §6 algorithms | The ported `EditorKitTests` editing suites pass (list in §5). |
| M2 | Library, import, timeline, preview playback, saving and undo | `LIB-*`, `IMP-*`, `TML-*`, `PRV-1…8`, `EDT`, `PRJ-*` | Create, open, autosave and delete projects; scrub, play, zoom. |
| M3 | Clip editing | `CLP-*`, `SPD-*`, `REV-*`, `FRZ-*`, `DUR-*`, trim, Voice (`CLP-5`) | Split, trim, speed, reverse, freeze, duplicate, delete, undo/redo. |
| M4 | Music and audio | `MUS-1…11`, `DNS-*` | Audio Tracks / From Video / Recent, full-length music, Cut, Start Here, Duck, Move to Start, Repeat, playing past the video. |
| M5 | Text, slides, watermark, canvas | `TXT-*`, `TTL-*`, `WMK-*`, `CNV-*` | Matches the iOS renders (compare screenshots). |
| M6 | Filters, adjust, crop, transitions, animation | `FLT-*`, `ADJ-*`, `CRP-*`, `TRN-*`, `ANM-*` | The golden maths table matches (§5). |
| M7 | Export and share | `EXP-*` | Same frames as the preview, same file naming, size estimate within 10%. |
| M8 | On-device AI | `CAP-*`, `ENH-1`, `RFR-1`, `CUT-*` | Works in airplane mode. |

Ship M0–M4 as the first internal build: that's a complete "photos and videos + music" editor.

---

## 5. Tests to port first

1. **Contract test** (IMPLEMENTATION §15.1): read `docs/spec/project.sample.json`, check every field, write it, read it again. Port the expected values from `ProjectFileContractTests` in `Tests/EditorKitTests/EditingTests.swift`.
2. **Core suites** from `Tests/EditorKitTests/EditingTests.swift`, keeping the names and prefixing the feature ID:
   MediaTime · Timeline layout · Split · Trim · Arrange · Ripple delete · Beat sync · Persistence · Undo / redo · Canvas · Photo duration · Audio editing · Empty projects · Music shows the whole song · Move audio to start · Repeat audio · Audio markers & sections · Caption styles · Remove caption fillers · CLP-5 no ducking over muted clips · TBR-1 Captions need a video clip · MUS-10 Recent audio tracks · MUS-11 Start here.
3. **Engine and intelligence** suites (`EngineTests.swift`, `IntelligenceTests.swift`): port them as instrumented tests once the engine exists. That includes `PRV-8 Preview plays music past the video`, which checks that the preview is longer than the export.
4. **Golden maths table:** not generated yet. Before M6, add an iOS test that writes the filter, adjustment, transition and animation outputs for fixed inputs to `docs/spec/golden.json`, and check that file on Android.
5. **UI tests:** port `Tests/CutlineUITests/FeatureUITests.swift` scenario by scenario, using the **same identifiers** (IMPLEMENTATION §13). Use resource IDs or Compose `testTag` with the same strings. Pass the test hooks (`-resetLibrary`, `-sampleMedia`, `-sampleCaptions`, `-demoMedia`) as instrumentation arguments.

---

## 6. Gotchas learned on iOS

These are behaviours that are easy to get subtly wrong. Each is in the spec; this list saves you finding them the hard way.

- **Music is full length.** Uncut music runs to the end of the song, not the end of the video (`MUS-3`). The timeline shows all of it and dims the part past the video. Export stops at the video's end.
- **Two lengths.** `Project.duration` (the edit, what's exported) and `Project.timelineDuration` (with music past the video, what's shown and previewed) are different. Mixing them up breaks export or the timeline.
- **Playing past the video** (`PRV-8`): while an audio clip is selected, Play continues to the end of the music. Otherwise it pauses at the video's end. Play at the end starts again from 0:00.
- **Start Here** (`MUS-11`) is one undo step: split, drop the left piece, move back to the lane's gap start, add a `0.3 s` fade-in. Then select, seek and play.
- **Cutting music** happens only from the toolbar (Cut, Start Here). There's no scissors button on the bar (`MUS-4`, removed on purpose).
- **Voice off** (`CLP-5`) mutes the clip and also stops music ducking over it, unless a voiceover plays there (IMPLEMENTATION §9.3).
- **Toolbar visibility** (`TBR-1`): with no content only Intro and Outro show; Captions needs a video clip. Export is hidden with no content, and Undo and Redo show only when they can act.
- **Swipe down to close panels** (`EDT-1`): measure the drag in screen coordinates. In Compose, put the drag modifier **before** `Modifier.offset`, or add up the drag deltas. Otherwise the panel moving under the finger cancels the drag and it never closes. Panels with a vertical list swipe only on their top row.
- **Pickers:** New Project and the timeline "+" open the **Photo Picker** straight away (no menu). Audio comes from Music → Audio Tracks (files) or From Video (the soundtrack of a picked video).
- **Recent tracks** (`MUS-10`) are app-wide copies, not references into a project. They must survive the project being deleted.
- **Dates:** `project.json` stores dates as seconds since **2001-01-01**, while `recent.json` uses **ISO 8601**.
- **Removed features stay removed:** no built-in music for users, no music Volume, no video Volume slider, no Media button in the main toolbar, no full-screen audio editor. See *Decisions and removed features* in FEATURES.md before adding any control.

---

## 7. Starting a session with an AI agent

Paste this as the first message of a new agent session to start a milestone:

```
You are porting Cutline to Android. Read AGENTS.md, docs/android/README.md,
docs/spec/FEATURES.md and docs/spec/IMPLEMENTATION.md first. The iOS code in this
repository is the reference.

Task: milestone M<n> (<feature IDs>) from docs/android/README.md §4.
- Port the matching iOS tests first (keep names, prefix feature IDs), then the code.
- Copy numbers and formulas from the spec exactly; don't invent behaviour.
- If the spec is unclear or wrong, stop and propose a spec change first.
- Update the parity table in docs/spec/FEATURES.md for every feature you finish.
- Put the feature IDs in the pull request title.
```

---

## 8. Keeping this guide current

When a feature changes on iOS, follow IMPLEMENTATION §15.3: FEATURES.md first, then IMPLEMENTATION.md, then the code. Then add a line under §6 here if the change is easy to get wrong on another platform.

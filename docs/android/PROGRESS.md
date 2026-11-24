# Android development progress (resume here)

**Last updated:** 2026-11-17 (Asia/Riyadh)  
**Branch:** `claude/android-app` (tracks `origin/claude/android-app`)  
**PR:** https://github.com/mujassir/video-editor/pull/24 → `develop`  
**Tip when this was written:** `c458c6a` — *LIB-1, MUS-2, EXP-1, LAY: make Robolectric UI tests pass*

This note is for picking up the port. Spec still wins: [FEATURES.md](../spec/FEATURES.md), [IMPLEMENTATION.md](../spec/IMPLEMENTATION.md), [AGENTS.md](../../AGENTS.md), kick-start [README.md](README.md).

---

## 1. How far we are

| Milestone | Status | Notes |
|---|---|---|
| **M0** Gradle + core model + project file contract | Done | `android/core`, `ProjectFileContractTest` |
| **M1** Core editing tests | Done | Ported iOS suites; 77+ core tests in the JVM suite |
| **M2** Library, import, timeline, preview, save, undo | Partial | UI + store wired; Media3 preview needs a device |
| **M3** Clip editing | Partial | Split / Voice / Speed / Freeze / Duplicate / Delete; **Reverse** not in toolbar |
| **M4** Music + Denoise | Partial | Music tools largely present; **Denoise UI** missing (model/composition hook exist) |
| **M5** Text, slides, watermark, canvas | Partial | Panels + raster; fonts mapped to open substitutes |
| **M6** Filters / adjust / crop / transitions / animation | Partial | Panels + core maths; no `golden.json` yet |
| **M7** Export + share | Partial | Media3 Transformer + estimate/share UI; not proven on device in CI |
| **M8** On-device AI | Partial | Enhance + Reframe (faces only); **no Cutout**, **no caption speech** |
| **M9** Tablet layout | Partial | Expanded ≥840 dp sidebar; phone portrait; Robolectric covers LAY-2 / LAY-6 |

**Parity table:** almost every Android column is 🟡 (partial). Denoise and Cutout are still ⬜. See FEATURES.md *Platform parity*.

**First internal build target (README):** ship M0–M4. That is not done yet.

---

## 2. What’s in the tree

```
android/
  core/     MediaTime, Project, Editing, EditSession, stores, render maths (JVM)
  engine/   Media3 composition/export, import, thumbs, waveforms, text, GL, Enhance, Reframe
  app/      Compose: library, editor (phone + wide), timeline, panels, export
```

Notable app/engine gaps called out in code:

- Toolbar hides **Captions generation**, **Denoise**, **Cutout**, **Reverse** until available (`EditorScreen.tools`).
- Captions panel: style/edit/fillers when segments exist; speech recognition not wired.
- Reframe: `FaceDetector` only; no saliency fallback when there are no faces.
- Transitions: main track is one Media3 sequence — overlap rendered as split halves (`CompositionBuilder`).

---

## 3. Tests that are green (local)

Run from `android/` with **JDK 21** (Gradle rejects newer Studio JBR 25):

```bash
export JAVA_HOME="$(brew --prefix openjdk@21)"
# or: /Applications/Android Studio.app/Contents/jbr/... only if it is 21.x
printf 'sdk.dir=%s\n' "$HOME/Library/Android/sdk" > local.properties   # gitignored
./gradlew :core:test :engine:testDebugUnitTest :app:testDebugUnitTest
```

**Last local run:** 93 tests, 0 failures (core + WAV probe + 8 Robolectric UI scenarios).

UI scenarios (feature IDs in names): `LIB-1`, `TBR-3`, `TXT-1`, `TTL-1`, `MUS-2`, `EXP-1`, `LAY-2`, `LAY-6`.

Fixes that made Robolectric pass (do not regress):

1. **LIB-1** — `CutlineUiTest.launch()` is idempotent (no second `setContent`).
2. **MUS-2** — `MediaImporter.probeWav` for sample tracks (no `MediaMetadataRetriever`).
3. **EXP-1** — export form uses `ExportEstimate` / `ExportRunner` so Media3 isn’t class-loaded for the options UI; overlay uses `pointerInput` (not `clickable`) so child `testTag`s aren’t merged away. `Exporter.supportsHevc()` short-circuits on Robolectric.

Roborazzi screenshot paths were configured as `build/screens/…`; confirm capture location if you need artefacts checked in.

---

## 4. Suggested next slices (in order)

1. **Android CI** — workflow: JDK 21 + the Gradle command above on `android/`.
2. **Device / emulator smoke** — Media3 `CompositionPreviewPlayer`, real export, Photo Picker.
3. **M3 leftover:** Reverse (`REV-*`) in the video clip toolbar + tests.
4. **M4 leftover:** Denoise UI (`DNS-*`) on the project-wide setting already in the model.
5. **M8:** on-device caption generation (`CAP-*`); Cutout when a bundled segmentation model is chosen (offline only).
6. Close remaining 🟡 items toward ✅; keep the parity table honest.

Do not re-plan M0–M1. Do not invent removed features (music Volume, video Volume, Minimal/Neon captions, scissors on the music bar, etc.).

---

## 5. Resume checklist for the next agent

1. `git fetch origin && git checkout claude/android-app && git pull`
2. Read this file, then [README.md](README.md) §4–§6 and the parity table.
3. Prefer continuing on `claude/android-app` / PR #24 unless told otherwise.
4. Put feature IDs in test names and PR titles; update the parity table when a slice finishes.
5. Environment: JDK 21, Android SDK (`local.properties`), no network/analytics SDKs.

---

## 6. Recent commits on this branch (newest first)

| Commit | Summary |
|---|---|
| `c458c6a` | Robolectric UI tests pass (LIB-1, MUS-2, EXP-1, LAY) + parity/README |
| `91423ab` | Robolectric UI tests + screenshots (written, then fixed in c458c6a) |
| `a6b0ad1` | Android UI: library, editor, timeline, panels, export |
| `168c807` | Android engine: import, thumbs, waveforms, text/slides, GL, composition, export, Enhance, Reframe |
| `11ae488` | M1 core editing tests |
| `0342355` | M0 Gradle + core + contract test |
| `d6d12e0` | Android guide readiness (before code landed) |

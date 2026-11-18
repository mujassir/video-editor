# Android development progress (resume here)

**Last updated:** 2026-11-18  
**Branch:** `cursor/android-app-complete-b64d` (from `develop`)  
**Tip when this was written:** §9.4 NoiseReducer + Cutout maths; CI uses preinstalled sdkmanager

This note is for picking up the port. Spec still wins: [FEATURES.md](../spec/FEATURES.md), [IMPLEMENTATION.md](../spec/IMPLEMENTATION.md), [AGENTS.md](../../AGENTS.md), kick-start [README.md](README.md).

---

## 1. How far we are

| Milestone | Status | Notes |
|---|---|---|
| **M0** Gradle + core model + project file contract | Done | `android/core`, `ProjectFileContractTest` |
| **M1** Core editing tests | Done | Ported iOS suites including SPD-4/5 |
| **M2** Library, import, timeline, preview, save, undo | Partial | UI + store wired; Media3 preview needs a device |
| **M3** Clip editing | Done for UI | Split / Voice / Speed (Apply to all) / Reverse / Freeze / Duplicate / Delete |
| **M4** Music + Denoise | Partial | Music tools; **spectral NoiseReducer** (§9.4) + WAV `nr2-` files + cleaned audio track in composition |
| **M5** Text, slides, watermark, canvas | Partial | Panels + raster; fonts mapped to open substitutes |
| **M6** Filters / adjust / crop / transitions / animation | Partial | Panels + core maths; no `golden.json` yet |
| **M7** Export + share | Partial | Media3 Transformer + estimate/share UI; not proven on device in CI |
| **M8** On-device AI | Partial | Enhance + Reframe; Cutout panel + §10.4 soft-edge maths; CAP-1 demo generate |
| **M9** Tablet layout | Partial | Expanded ≥840 dp sidebar; phone portrait; Robolectric covers both |

**First internal build (M0–M4):** usable for photos + videos + music + denoise. Device smoke for Media3 preview/export still open.

---

## 2. What’s in the tree

```
android/
  core/     MediaTime, Project, Editing (incl. SPD-4/5 retime), EditSession, stores, render maths
  engine/   Media3, NoiseReducer (§9.4), Cutout maths, Enhance, Reframe, MediaProcessing, export
  app/      Compose: library, editor (phone + wide), timeline, panels, export
```

Remaining gaps:

- Real reverse re-encode (today: prepared file copy under `rev-…`).
- Cutout person-segmentation (ML Kit / MediaPipe) into the live compositor (maths ready).
- On-device speech for CAP-1 (sample/demo captions work in tests).
- Reframe saliency fallback; `golden.json` for M6; device/emulator Media3 smoke.

---

## 3. Tests that are green (local)

```bash
cd android
# local.properties → sdk.dir=…
./gradlew :core:test :engine:testDebugUnitTest :app:testDebugUnitTest
```

UI scenarios (phone + tablet): LIB, TBR, TXT, TTL, MUS, EXP, DUR, ANM, ADJ, CRP, CNV, WMK, PRJ-2, DNS, CAP, REV, CUT, SPD, LAY-2/6.

Engine: `NoiseReducerTest` (hiss/tone/DNS-6), `CutoutTest` (soft edge + Transparent).

CI: `.github/workflows/android.yml` (JDK 21, platform 35, preinstalled sdkmanager).

---

## 4. Suggested next slices

1. Device / emulator smoke — Media3 preview, real export, Photo Picker.
2. Real reverse encoder (windowed frame reverse → HEVC).
3. Bundled offline segmentation for Cutout; speech model for CAP-1.
4. Close remaining 🟡 items toward ✅; keep the parity table honest.

Do not invent removed features (music Volume, video Volume, Minimal/Neon captions, scissors on the music bar, etc.).

---

## 5. Resume checklist

1. `git fetch origin && git checkout cursor/android-app-complete-b64d && git pull` (or continue from `develop` + this branch).
2. Read this file, then [README.md](README.md) §4–§6 and the parity table.
3. Put feature IDs in test names and PR titles; update the parity table when a slice finishes.
4. Environment: JDK 21, Android SDK (`local.properties`), no network/analytics SDKs.

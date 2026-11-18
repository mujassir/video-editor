# Cutline: Feature Specification

**Status:** describes the iOS app as built (reference implementation).
**Applies to:** iOS (shipping), Android (next), macOS and Windows (later). Starting Android: see [docs/android/README.md](../android/README.md).
**Companion documents:**
- [IMPLEMENTATION.md](IMPLEMENTATION.md): how each feature works internally, with exact numbers and formulas.
- [project.sample.json](project.sample.json): the shared project file format.

This document says **what the user sees and can do**. If two apps behave differently, this document decides which one is right. Change it first, then the apps.

## How to use this spec

- **Every feature has an ID** (for example `MUS-3`). Use it in tickets, pull requests and test names, so a feature can be traced across platforms.
- **"Must", "should" and "may"** mean what they say. *Must* is required for parity. *Should* is expected unless the platform makes it impractical, and the exception goes in the [parity table](#platform-parity). *May* is optional.
- **Values in `code font`** are exact. Use the same numbers, names and defaults everywhere, because projects move between devices and must look and sound the same.
- **Removed features** are listed in [Decisions](#decisions-and-removed-features). Don't bring them back without updating this spec first.
- **AI agents:** read this file and IMPLEMENTATION.md before changing behaviour. If code and spec disagree, flag it rather than silently picking one.

---

## 1. Product principles

These apply to every feature on every platform.

1. **Private by default.** All processing happens on the device: import, editing, AI, rendering and export. No account, no uploads, no analytics on content, no server fallback for AI. If a platform can't do an AI feature on the device, the feature is hidden there, not sent to a server.
2. **No watermark** unless the user adds their own (`WMK-*`).
3. **Every edit is undoable.** One user action is one undo step. A slider drag is one step, however long it lasts.
4. **Nothing is lost.** The project saves automatically. A crash can't corrupt a project. Media is copied into the project, so moving or deleting the original file doesn't break the edit.
5. **What you see is what you export.** The preview and the export use the same rendering rules. Paused frames show clips at rest (see `PRV-3`); playback and export show animations.
6. **One accent colour, dark UI.** See [Visual language](#13-visual-language).
7. **Short, plain messages.** Toasts say what happened ("Split at 0:03.2", "Removed 3 filler words") or what's wrong and what to do ("Select a video clip").

---

## 2. Glossary

| Term | Meaning |
|---|---|
| **Project** | One edit: its clips, audio, text, captions, settings and copied media. |
| **Media item** | A file copied into the project (video, photo or audio). Several clips can use the same media item. |
| **Main track** | The single row of video and photo clips, played back to back ("magnetic"). |
| **Clip** | A piece of the main track: a video clip, a photo clip, a freeze frame or a title slide. |
| **Still** | A photo clip or a freeze frame. |
| **Audio clip** | Free-positioned audio on its own lane: music, voiceover, sound effect or extracted audio. |
| **Lane** | A row for audio clips. Clips on one lane never overlap. |
| **Text overlay** | Text placed over the video for a time range. |
| **Captions** | Word-timed subtitles made from speech, shown one short segment at a time. |
| **Canvas** | The output frame, with an aspect ratio (9:16, 3:4, 1:1, 4:5, 16:9). |
| **Playhead** | The current time. On the timeline it's a fixed vertical line in the centre. |
| **Selection** | What the toolbar acts on: nothing, a clip, a text, an audio clip, or the captions. |
| **Panel** | The settings area that replaces the toolbar while a tool is open. It closes with ✓. |
| **Toast** | A short message near the top of the editor that disappears by itself. |

---

## 3. Screens

### LIB: Project library (home)

- **LIB-1 New Project:** a large card at the top, "New Project / Edit videos and photos with on-device AI". Tapping it creates a project named `Project N` (N = number of projects + 1), opens the editor and **immediately opens the Photos library** (the same picker as `IMP-1`: videos and photos, up to `20`). The picked media goes on the main track and the user can start editing. Cancelling the picker leaves the empty editor open (the empty preview and the timeline "+" still work, `PRV-7`), and closing an empty editor deletes the project (`LIB-4`). Opening an existing project never opens the picker.
- **LIB-2 Recent:** a 2-column grid of project cards, most recently modified first. Each card shows:
  - **Thumbnail:** the first clip's first frame, cropped to fill a fixed `150 pt` high box, rounded corners. A placeholder film icon when there's no thumbnail. Cards must never overlap, whatever the project's aspect ratio.
  - **Duration badge:** in the bottom-right corner, `m:ss.f`.
  - **Name:** one line.
  - **Relative modified time:** for example "5 min".
- **LIB-3 Card actions:** long press opens Rename, Duplicate and Delete (destructive). Duplicate copies the whole project folder and names the copy "<name> Copy".
- **LIB-4 Empty projects:** a project with no clips, audio, text or captions is deleted when the editor closes and on app start. The library never shows an empty "0:00" project.
- **LIB-5 Privacy note:** at the bottom, a lock icon with "Everything runs on your iPhone. No account, no uploads, no watermark." Platforms use their own device word, such as "iPad", "phone" or "computer" (`LAY-8`).

### EDT: Editor layout (top to bottom)

1. **Top bar:**
   - **Close (×):** saves the project, writes its thumbnail and returns to the library.
   - **Aspect ratio button:** shows the ratio, such as `9:16`, and opens Canvas (`CNV-1`).
   - **Undo and Redo:** each is shown only when it can do something, and hidden otherwise. A new project shows neither. Undo appears after the first edit. Redo appears only after an undo, and disappears again once there's nothing left to redo or a new edit clears it (`PRJ-2`).
   - **Export:** an accent capsule. **Hidden** while there's nothing to export, that is while the edit has no length (`Project.duration == 0`: no clips and no voiceover; music or text on their own don't count). It appears as soon as there is.
2. **Preview:** the canvas at its aspect ratio. Tapping it plays or pauses.
3. **Transport:** current time `m:ss.f`, "/ total", and a play/pause button.
4. **Timeline:** see `TML-*`.
5. **Bottom area:** the toolbar for the current selection, or the open panel.
   - **EDT-1 Swipe down to close a panel:** every bottom panel (Music, Captions, Text, Watermark, Filters, …) has a grabber bar at the top. A **short swipe down anywhere on the panel** closes it, the same as ✓: letting go after more than `30 pt`, or a quick flick (predicted `80 pt`). While dragging, the panel follows the finger (measured in screen coordinates); a shorter drag springs back. Only mostly-vertical drags count, so horizontal sliders and buttons inside keep working. Panels with a vertically scrolling list (Adjust, Text, Captions, Animate, Animate Text) only swipe on the grabber and title row, so scrolling never closes them. **Exception:** on Intro/Outro (`TTL-*`) a swipe closes without adding or saving the slide; only ✓ does that.

Overlays:
- **Toast:** appears at the top, about 2.2 s.
- **Busy overlay:** dims the screen, shows a message ("Reducing noise…") and a progress ring when progress is known. Playback pauses.

### LAY: Phone and wide (tablet) layouts

The editor has two layouts. Which one is used depends on the **width of the app's window**, not on the device, so an iPad in Split View or Slide Over gets the phone layout when its window is narrow.

- **LAY-1 Choosing the layout:**
  - **Wide** when the window is at least `840 pt` wide **and** the platform reports a regular (non-compact) width. This is the Material "expanded" breakpoint, so Android tablets switch at the same width.
  - **Phone** otherwise. This is the layout in `EDT` above.
  - The choice is re-checked whenever the window changes size (rotation, Split View, Stage Manager). The playhead, selection, open panel and playback carry over unchanged; nothing is rebuilt or lost.
  - In practice: every iPad in landscape and the 13-inch iPad Pro in portrait are wide. Smaller iPads in portrait, and every phone, use the phone layout.
- **LAY-2 Wide editor, top to bottom:**
  1. **Top bar:** the same as `EDT`.
  2. **Middle row:**
     - On the left, the **preview** with the **transport** under it, taking the remaining width.
     - On the right, the **sidebar** (`LAY-3`): `clamp(0.3 × window width, 340, 420) pt` wide, the full height of the row, surface colour, with a hairline border on its left. Tool tiles inside it use the raised surface colour.
  3. **Timeline:** full window width under the middle row. It's the same timeline (`TML-*`), with a taller lane area: height `min(320, 170 + lanes × 38) pt`.
- **LAY-3 Sidebar:** replaces the bottom area of the phone layout.
  - **No panel open:** a heading naming the selection, then that selection's tools as a **grid of 3 columns**. The heading is one of Project, Video Clip, Photo, Text, Music, Audio (a voiceover or other non-music audio) or Captions. The grid has the **same tools, order, names, highlights and visibility rules** as the phone toolbar (`TBR-*`).
  - **A panel open:** the panel fills the sidebar from the top and scrolls vertically if it's taller. It has the same title, ✓, Undo and contents as on the phone.
  - **No swipe-down:** there's no grabber and no swipe-down to close (`EDT-1` applies to the phone layout only). ✓, Esc on a keyboard, or picking another tool closes it.
  - **Full-screen screens stay full screen:** Export and the caption text editor are centred, at most `720 pt` wide (`LAY-6`).
- **LAY-4 Orientation:**
  - **Phones:** portrait only (see *Decisions*).
  - **Tablets:** all four orientations.
  - **Desktop:** a resizable window, using the same width rule.
- **LAY-5 Keyboard shortcuts:** these work with a hardware keyboard in **either** layout, and are listed in the system's shortcut overlay (holding ⌘ on iPad). Keys without a modifier (Space, arrows, Delete) are ignored while a text field has focus, so typing never triggers them.

  | Key | Action |
  |---|---|
  | Space | Play / pause |
  | ← / → | Step back / forward one frame (`1/30 s`) |
  | ⇧← / ⇧→ | Step back / forward `1 s` |
  | ⌘Z / ⇧⌘Z | Undo / Redo (only when possible, `PRJ-2`) |
  | ⌘B | Split at the playhead (`CLP-1`) |
  | Delete (⌫) | Delete the selection |
  | Esc | Close the open panel; with no panel, clear the selection |
  | ⌘E | Export (only when the Export button is shown) |
- **LAY-6 Other screens on wide windows:**
  - **Library:** the "Recent" grid uses as many columns as fit at least `220 pt` each, with a `14 pt` gap, and keeps cards at their phone size. The New Project card is at most `720 pt` wide, and the page content is at most `1200 pt` wide, centred.
  - **Export** and the **caption text editor** are centred, at most `720 pt` wide.
- **LAY-7 Pointer:** with a mouse or trackpad, buttons, chips and tool tiles show the platform's standard hover highlight.
- **LAY-8 Device word:** the library's privacy note (`LIB-5`) uses the device's own word: "iPhone" or "iPad".

### EXP: Export screen

A full-screen sheet; see `EXP-*`.

---

## 4. Timeline (TML)

- **TML-1 Fixed centre playhead:** the white playhead line stays in the middle and the content scrolls under it. Scrolling scrubs the preview.
- **TML-2 Zoom:** pinch to zoom between `12` and `400` points per second; the default is `64`.
- **TML-3 Rows**, from top to bottom:
  - Ruler.
  - Main track: filmstrip thumbnails, `58 pt` high.
  - Text lane.
  - Captions lane.
  - Audio lanes: `30 pt` each, `4 pt` apart, as many as needed.
- **TML-4 Clip colours:**
  - Video: `#4073F2` (0.25, 0.45, 0.95).
  - Audio: `#33BF8C` (0.20, 0.75, 0.55).
  - Text: `#F29933` (0.95, 0.60, 0.20).
  - Captions: `#B373F2` (0.70, 0.45, 0.95).
- **TML-5 Select:** tap an item to select it, and tap it again to deselect. Tapping empty space deselects. The toolbar changes to match the selection (`TBR-*`).
- **TML-6 Trim handles:** a selected main-track clip shows handles on both ends (`16 pt` wide).
  - Dragging a handle trims live; the preview follows the edge being dragged.
  - One drag is one undo step.
  - The clip is never shorter than `0.1 s`, and a video can't go past the ends of its source file.
- **TML-7 Transition buttons:** a small button between two clips opens the Transition panel for the cut (`TRN-*`).
- **TML-8 Add button:** a "+" after the last clip opens Add media (`IMP-*`).
- **TML-9 Music past the end:** music longer than the video is drawn in full. The part past the end of the video is dimmed. The playhead may move past the end of the video over music, so you can cut there; the preview holds the last frame.
- **TML-10 Move audio:** press and hold an audio bar for `0.25 s`, then drag it. The new start snaps to a frame at `30 fps`.
- **TML-11 Scissors on music:** *(removed: music is cut with Cut in the toolbar, `MUS-4`.)*
- **TML-12 Waveforms** are drawn on audio bars. Clip thumbnails load in the background.
- **TML-13 Drag to reorder:** press and hold a video or photo on the main track for `0.3 s`, then drag it left or right.
  - **Thumbnail strip:** while dragging, the main track turns into a row of square thumbnails, one per clip (`52 pt`, `6 pt` apart, rounded `8 pt`), so any number of clips fits at a glance. Each shows the frame from the middle of the clip (a photo shows the photo). The other rows dim to `40%`.
  - **The picked clip** floats under the finger as a larger thumbnail (`1.25×`, with a shadow). The other thumbnails slide aside (`0.2 s`) to open the gap where it will land.
  - **Landing slot:** from the floating thumbnail's centre, `round((x − 26) / 58)` along the strip, kept inside the movable range (IMPLEMENTATION §6.2).
  - **Slides:** the opening and closing slides (`TTL-4`) show in the strip but dimmed to `50%`, can't be picked up, and nothing lands before the opening or after the closing slide.
  - **Auto-scroll:** within `60 pt` of either screen edge the strip scrolls by itself, faster closer to the edge, up to `600 pt/s`.
  - **Letting go** drops the clip, and the timeline returns to normal. Dropping where it started changes nothing.
  - A move is one undo step, selects the moved clip and moves the playhead to its start. Toast: "Moved to position N of M", counting only movable clips. The transition rule of `CLP-4` applies.
  - There's no menu on press and hold (see *Decisions*).

---

## 5. Preview and playback (PRV)

- **PRV-1 Play/pause:** tap the preview or the play button. Playback stops at the end of the video, and pressing play at the end starts again from 0. **Exception:** while an audio clip is selected, see `PRV-8`.
- **PRV-8 Listen past the video:** while an audio clip is selected, Play continues past the end of the video to the end of the music (the end of the timeline), so the whole song can be heard and cut there (`MUS-4`, `MUS-11`). Pressing play with the playhead after the end of the video plays from there; only at the end of the music does play start again from 0. Past the end of the video the preview is dimmed with "Music only · not in export". Deselecting while playing past the end pauses where it is. Export is unchanged: it still stops at the end of the video.
- **PRV-9 Play speed:** a button at the right end of the time row under the preview shows the play speed ("1×"). Tapping it opens a column of round buttons above it, over the preview, fastest on top: **2× · 1.5× · 1.25× · 1× · 0.75× · 0.5×**. The current speed is filled in. Tapping one sets it and closes the column; tapping the speed button again closes it too. Picked while playing, the new speed takes effect at once. Picked while paused, playback starts at the new speed (from 0 if the playhead is at the end, like `PRV-1`). It only changes how fast the preview plays, with the pitch kept. It isn't saved in the project, isn't an undo step, and doesn't change the export. It starts at 1× each time the editor opens and stays as picked until the editor closes. Clip speed (`SPD-1`) is separate and does change the export.
- **PRV-7 Empty preview:** while the main track has no clips (a new project, or after deleting every clip), the preview shows a film icon and "Add videos or photos to start". Tapping the icon or the text opens the Photos library, the same as the timeline "+" (`IMP-1`).
- **PRV-2 No black flash:** after an edit, the last frame stays on screen until the updated preview is ready.
- **PRV-3 Animations only while playing:** animations play only during playback and export. This covers In/Out/Combo, photo motion and text animations. Paused or scrubbing, clips and text are shown at rest, so edits can be judged. Transitions always show.
- **PRV-4 Clean frame:** opening Filters, Adjust, Crop, Cutout, Speed or Duration moves the playhead to a frame of the selected clip where no animation, transition or fade is active. It stays put if it's already on such a frame.
- **PRV-5 Panels preview their effect:** choosing an animation or transition plays the part of the clip where it happens:
  - **In animation:** plays from the start of the clip.
  - **Out animation:** plays the last `1.5 s`.
  - **Transition:** plays from `0.4 s` before the transition.
- **PRV-6 Drag text on the preview:** drag the selected text to place it anywhere. This sets the text's position to Custom (`TXT-5`).

---

## 6. Toolbars (TBR)

The toolbar is one horizontally scrolling row of icon buttons with labels. The order is fixed and must match on every platform. A button with an **AI** badge runs an on-device AI feature. *Active* means the button is drawn highlighted.

| Selection | Buttons, in order |
|---|---|
| **TBR-1 Nothing** | With **no content** (the edit has no length, as for Export: no clips, slides or voiceover) only **Intro · Outro** show. Otherwise: Music · Captions (AI; **hidden** until the main track has a video clip: not shown for an empty project or one with only photos, slides or freeze frames) · Denoise (`DNS-1`; active if on; **hidden** like Captions until the main track has a video clip) · Watermark (active if set) · Text · Intro · Outro |
| **TBR-2 Video clip** | Split · Voice (`CLP-5`; active while the voice is off) · Speed · Animate (active if any animation) · Filters · Adjust · Enhance (AI) · Cutout (AI) · Reframe (AI) · Crop · Reverse (active if reversed) · Freeze · Duplicate · Delete |
| **TBR-3 Photo or freeze frame** | Duration · Animate (active if motion or animation) · Filters · Adjust · Enhance (AI) · Cutout (AI) · Crop · Duplicate · Delete |
| **TBR-4 Text** | Edit · Duration · Animate (active if set) · Position (active if a fixed spot) · Duplicate · Delete |
| **TBR-5 Music** | Cut · Start Here (`MUS-11`; only while the playhead is inside the clip) · Duck · Move to Start (only when there's a gap before it) · Repeat (only when it ends before the video) · Delete |
| **TBR-5b Other audio** (voiceover, extracted, effect) | Cut · Start Here (conditional) · Move to Start (conditional) · Repeat (conditional) · Delete |
| **TBR-6 Captions** | Edit · Style · Fillers · Delete |

Deleting closes any open panel and clears the selection.

---

## 7. Import (IMP)

- **IMP-1 Add media:** the timeline "+" at the end of the main track, or the empty preview (`PRV-7`), opens the **Photos library** directly: videos and photos, up to `20` at once. (A new project opens it straight away too, `LIB-1`.) Audio is added from Music (`MUS-1`).
- **IMP-2 Copy in:** each file is copied into the project's media folder under a new unique name. The original isn't needed afterwards.
- **IMP-3 Placement:** videos and photos go to the end of the main track, in the order picked. Photos last `3 s`. Audio files go on the first free audio lane as music.
- **IMP-4 Orientation:** video recorded in portrait (rotated in the file) is shown upright. Photos are shown upright using their orientation tag.
- **IMP-5 Canvas fit:** new clips use the project's canvas fit and position, if they've been set (`CNV-2`).
- **IMP-6 Errors:** if nothing could be imported, the toast says "Couldn't import that file".

---

## 8. Main-track clip features

### CLP: Common clip editing

- **CLP-1 Split:** splits the clip under the playhead. Toast: "Split at m:ss.f". The right-hand piece gets a new identity. A transition stays on the right-hand piece's cut. A split closer than `0.1 s` to either edge is refused ("Too close to the clip edge").
- **CLP-2 Duplicate:** inserts a copy right after the clip.
- **CLP-3 Delete:** removes the clip, and the following clips move up. Deleting the last clip also removes the transition on the new last clip.
- **CLP-4 Reorder:** by dragging on the timeline (`TML-13`). When clips are reordered, the clip that ends up last never keeps a transition.
- **CLP-5 Voice:** toggles the clip's own sound off and on (`isMuted`). The button shows a mic, or a slashed mic and is drawn active while the sound is off. Toast: "Voice off" / "Voice on". A clip whose media has no sound isn't changed (toast: "This clip has no sound"). The clip shows a 🔇 badge on the timeline while its voice is off. Music isn't ducked over a clip whose voice is off (IMPLEMENTATION §9.3).

### SPD: Speed

- **SPD-1 Range:** speed runs from `0.1×` to `10×` on a logarithmic slider, rounded to `0.05`.
  - **Quick picks:** `.3×`, `.5×`, `1×`, `2×`, `3×`, `4×` (`0.3×` and `0.5×`, labelled without the leading zero).
  - **Readout:** the current value, for example "1.5×".
- **SPD-2 Duration:** changing the speed changes how long the clip lasts on the timeline (source length ÷ speed). Stills ignore speed.
- **SPD-3 Smooth slow motion:** below `1×`, consecutive source frames are blended, so motion looks smooth rather than stepped.
- **SPD-4 Apply to all clips:** under the quick picks, an "Apply to all N clips" button (N = the number of video clips on the main track that aren't freeze frames) sets the current speed on every one of them. Photos, title slides and freeze frames have no speed and are skipped. The button shows only when N is at least 2. It's one undo step. Toast: "All clips set to 2×" (the speed as in the quick picks).
- **SPD-5 Captions follow the speed:** when a clip's speed changes (`SPD-1` or `SPD-4`), captions, text, voiceovers and extracted audio stay with the moment of the video they belong to. Those on a sped-up clip move closer together, those after it move earlier, and so on, so each caption word stays on its speech. Text keeps its length within `0.5…30 s`. Voiceovers and extracted audio only move; their length doesn't change. Music isn't moved. IMPLEMENTATION §6.2 *Re-timing after a speed change* has the exact rule.

### REV: Reverse

- **REV-1 Toggle:** the button turns reverse on or off. The first time, a reversed copy of the video is made (busy overlay "Reversing clip…"); after that, toggling is instant.
- **REV-2 Sound:** reversed clips play without sound.
- **REV-3 Limits:** only video clips that aren't freeze frames can be reversed.

### FRZ: Freeze frame

- **FRZ-1 Insert:** inserts a `1.5 s` still of the frame under the playhead, splitting the clip around it. Toast: "Freeze frame added".
  - The still always plays at `1×`, not reversed.
  - Near a clip edge (under `0.1 s` away), the still goes before or after the clip instead of splitting it.
- **FRZ-2 Treated as a photo:** a freeze frame gets the photo toolbar.

### DNS: Noise reduction (Denoise)

Noise reduction is **one setting for the whole video**, not per clip. It's in the main toolbar (`TBR-1`), not the clip toolbar.

- **DNS-1 Panel** "Noise Reduction":
  - Text: "Removes background hiss, hum, wind and room noise from the sound of every video clip."
  - Choices: **Off · Low · Medium · High**.
  - Note: "Stronger settings remove more noise but can make voices sound thinner."
- **DNS-2 Processing:** picking a level cleans the sound of every video in the edit on the device, with a busy overlay "Reducing noise…" and a progress ring. Toast: "Noise reduced (Medium)".
- **DNS-3 Reuse:** the cleaned audio is made once per media item and level. Later switches to an already-made level are instant. Split pieces of the same video share it. Sound cleaned by an older version of the app is cleaned again the next time that level is picked.
- **DNS-4 Scope:** it applies to the own sound of every video clip on the main track, in preview and export. Music, voiceover and other audio clips aren't changed. Off restores the original sound everywhere.
- **DNS-7 New clips:** while it's on, videos added later are cleaned straight away (same busy overlay), so the whole edit stays at one level.
- **DNS-8 Older projects:** a project saved with per-clip settings plays as saved until a level (or Off) is picked in the panel. Picking one replaces every per-clip setting.
- **DNS-6 Quiet starts:** a silent or very quiet stretch, such as a fade-in, the mic starting up or a muted moment, doesn't stop the noise from being removed from the rest of the clip.
- **DNS-5 No sound:** if no video in the edit has sound, picking a level shows the toast "This video has no sound".

### FLT: Filters

- **FLT-1 Choice:** "None" plus `20` looks, in this order:
  - Vivid, Warm, Cool, Cinema, Film, Fade, Vintage, Mono, Noir, Sepia.
  - Pastel, Punch, Golden Hour, Moody, Lush, Bleach, Night, Rose, Matte, Chrome.
- **FLT-2 Thumbnails:** each look's thumbnail is the clip's own frame with that look applied.
- **FLT-3 Intensity:** a slider from `0`–`100%`, default `100%`. It's shown only when a look is chosen.
- **FLT-4 Exact looks:** looks must match across platforms; the formulas are in IMPLEMENTATION §8.4.

### ADJ: Adjust

- **ADJ-1 Sliders:**
  - From `-100` to `+100` (stored as `-1…1`), neutral at 0: Exposure, Contrast, Saturation, Warmth, Highlights, Shadows.
  - From `0` to `100`: Vignette, Sharpen.
- **ADJ-2 Buttons:** **Auto Enhance** runs `ENH-1`. **Reset** returns every slider to neutral.

### CRP: Crop and rotate

- **CRP-1 Rotate** turns the clip 90° clockwise each time. **Flip H** and **Flip V** mirror it.
- **CRP-2 Fit for this clip:** a button that cycles Fit → Fill → Stretch.
- **CRP-3 Zoom:** a slider from `0.5×` to `3×`.
- **CRP-4 Crop presets:** Original, 1:1, 4:5, 16:9. Each is a centred crop of the source.

### TRN: Transitions

- **TRN-1 Choice:** None plus `8` kinds:
  - Fade (dip to black), Dissolve, Slide, Push Up.
  - Zoom, Wipe, Blur, Glitch.
- **TRN-2 Duration:** a slider from `0.2 s` to `2 s`, default `0.5 s`. The actual overlap is never more than half of either clip.
- **TRN-3 Shorter video:** a transition overlaps the two clips, so the video gets shorter by the transition's length.
- **TRN-4 Last clip:** the last clip never has a transition.

### ANM: Animate (clips and photos)

- **ANM-1 Tabs:** **In · Out · Combo** for video clips, and **In · Out · Combo · Motion** for photos and freeze frames. Each tab is a grid of tiles with "None" first.
- **ANM-2 In / Out** (14 kinds):
  - Fade, Zoom In, Zoom Out, Slide ←, Slide →, Slide ↑, Slide ↓.
  - Rotate, Spin, Pop, Bounce, Drop, Blur, Swing.
  - Out plays the same animation backwards.
  - **Length:** a slider from `0.2 s` to `3 s`, default `0.6 s`. In and Out each take at most half the clip, so they never overlap.
- **ANM-3 Combo** loops for the whole clip (8 kinds): Pulse, Heartbeat, Shake, Wobble, Swing, Float, Rock, Spin.
- **ANM-4 Motion** (photos and freeze frames): None, Zoom In, Zoom Out, Pan Left, Pan Right, Pan Up, Pan Down, Ken Burns. The camera move is eased and never shows the photo's edges when it fills the canvas.
- **ANM-5 Apply to all:** shown when there's more than one clip.
  - On In/Out/Combo, "Apply to all clips" copies this clip's animation to every clip.
  - On Motion, "Apply to all photos" copies it to every photo.
  - Toasts: "Applied to all clips" and "Applied to all photos".

### DUR: Photo duration

- **DUR-1 Slider:** from `0.5 s` to `30 s` in `0.1 s` steps, with a large readout "3.0 s".
- **DUR-2 Quick picks:** `2s`, `3s`, `5s`, `10s`.
- **DUR-3 Apply to all:** "Apply to all N photos", shown when there are 2 or more photos. Toast: "All photos set to X s".

### ENH: Auto Enhance (AI)

- **ENH-1 What it does:** measures the clip's brightness, contrast, colour and colour cast, then sets the Adjust sliders to correct them.
  - It analyses 3 frames, at 20%, 50% and 80% of the clip, or the photo itself.
  - It replaces the Adjust values, and undo restores them.
  - Toast: "Enhanced".

### CUT: Cutout (background removal, AI)

- **CUT-1 Panel** "Remove Background":
  - Text: "Cuts out people automatically – no green screen."
  - Choices: **Off · Blur · Canvas**, plus a row of colour swatches.
- **CUT-2 What each choice does:** people are cut out on every frame.
  - **Blur:** a blurred version of the clip shows behind them.
  - **Canvas:** the project's canvas background shows behind them.
  - **Colour:** the chosen solid colour shows behind them.
- **CUT-3 Quality:** the export uses the most accurate cut-out; the preview may use a faster one.

### RFR: Auto Reframe (AI)

- **RFR-1 What it does** (video clips only): tracks faces, or the most noticeable subject, through the clip. The crop then follows them, so a wide shot can fill a vertical canvas.
  - The clip is switched to Fill.
  - Toast: "Reframed to follow the subject".
  - With nothing selected, or a photo selected: "Select a video clip".

---

## 9. Canvas, slides and watermark

### CNV: Canvas

- **CNV-1 Aspect ratio:** `9:16` (default), `3:4`, `1:1`, `4:5`, `16:9`.
- **CNV-2 "Media that doesn't fit":**
  - **Fit / Fill / Stretch** (default Fit).
  - With Fit or Fill, a position: Center, Top, Bottom, Left, Right.
  - The choice applies to every clip except title slides, and to clips added later.
- **CNV-3 Background:** behind fitted media, the background is a blurred, darkened copy of the current frame (default), or a solid colour.

### TTL: Opening and closing slides (Intro and Outro)

- **TTL-1 Panel** "Opening Slide" or "Closing Slide":
  - Title and an optional subtitle.
  - `7` style presets: Midnight, Sunset, Ocean, Forest, Grape, Paper, Noir.
  - Duration from `1`–`10 s`, default `3 s`.
- **TTL-2 Saving:** ✓ adds the slide or saves changes, then closes the panel. Hint: "Tap ✓ to add the slide" or "Tap ✓ to save changes". **Remove** deletes it.
- **TTL-3 Defaults:** the opening title starts as the project name; the closing title as "Thanks for watching".
- **TTL-4 Placement:** the opening slide is always the first clip and the closing slide the last. The slide's layout fits any canvas ratio. Animations and transitions work on slides.

### WMK: Watermark

- **WMK-1 Kind:** **Text** (default text "@yourname") or **Image** (picked from Photos). **Remove** deletes it.
- **WMK-2 Settings:**
  - Position: a 3×3 grid, default Bottom Right.
  - Size from `8`–`50%`, default `22%`.
  - Opacity from `10`–`100%`, default `70%`.
- **WMK-3 Coverage:** it shows over the whole video, above clips and text, below captions, including exports.

---

## 10. Text (TXT)

- **TXT-1 Add:** Text adds "Your text" at the playhead for `3 s`. It pops in and fades out (`0.4 s` each). It's selected, and the Edit panel opens.
- **TXT-2 Edit panel** "Text":
  - **Text field.**
  - **Fonts** (8): Bold, Classic, Rounded, Condensed, Elegant, Mono, Script, Heavy.
  - **Colour swatches** (8): white, black, yellow, coral, blue, green, purple, orange.
  - **Toggles:** Outline, Label (dark rounded box behind the text), Shadow (default on).
  - **Size:** a slider shown as `30`–`160`.
- **TXT-3 Duration** "Text Duration":
  - Slider from `0.5`–`30 s`, and quick picks `2/3/5/10s`.
  - **Start at playhead:** moves the text to start at the playhead.
  - **Whole video:** covers the whole video.
- **TXT-4 Animate:** In / Out / Combo, with the same sets and length range as `ANM-2` and `ANM-3`.
- **TXT-5 Position:**
  - A 3×3 grid of fixed spots that keep the text inside the video at that edge.
  - **Custom:** free position. Dragging the text on the preview also sets Custom.
- **TXT-6 Duplicate:** places the copy right after the original.

---

## 11. Music and audio (MUS)

- **MUS-1 Add music** (Music in the main toolbar):
  - **Audio Tracks** (music-note icon): your own audio file (opens Files).
  - **From Video:** the soundtrack of a video from Photos.
  - **Recent** (`MUS-10`): under the two buttons, when there are any.
- **MUS-2 New music defaults:**
  - Volume `70%`.
  - Fade-out at the end: `min(1.5 s, song length ÷ 4)`.
  - Auto-duck **on** at `25%`.
  - It starts where the existing music ends, if that's inside the video, otherwise at 0:00. It goes on the first lane where it fits (`MUS-9`).
  - Toast: "Added <name>".
- **MUS-3 Whole song:** music that hasn't been cut runs from its start to the end of the song file, however long the video is (see `TML-9`). Preview and export stop at the end of the video.
- **MUS-4 Cut:** splits the music at the playhead. Toast: "Cut at m:ss.f". Each piece is its own clip, and the right-hand piece becomes selected.
  - Only **Cut** in the toolbar cuts music; there's no scissors button on the music bar.
- **MUS-5 Duck** (music only) opens the "Duck" panel:
  - Text: "Music volume while someone is speaking".
  - **Music slider:** `0`–`100%` in `5%` steps, default `25%`. Moving it also turns auto-duck on.
  - **Without captions:** "Ducking finds speech from captions. Add captions to hear it."
  - **How it sounds:** while captioned speech plays, the music dips to the chosen level, and back up afterwards. See IMPLEMENTATION §9.2–9.3.
- **MUS-6 Move to Start:** shown only when there's blank space of at least `0.2 s` before the clip on its lane. It moves the clip back to the end of the previous clip on that lane, or to 0:00. Toast: "Moved to m:ss.f".
- **MUS-7 Repeat:** shown only when the clip ends at least `0.2 s` before the video ends. It adds copies back to back until the end of the video; the last copy is cut at the end and keeps the fade-out.
  - Toast: "Repeated N× to the end".
  - If the clip already reaches the end: "Already plays to the end".
- **MUS-8 Move:** see `TML-10`. **Delete** removes the audio clip.
- **MUS-9 Lanes:** a new audio clip goes on the first lane where it doesn't overlap anything.
- **MUS-11 Start Here:** one tap makes the selected audio play from the playhead's point in the song. Shown while the playhead is inside the clip, at least `0.2 s` from its ends (it can be past the end of the video, over the dimmed part). As **one** undo step it:
  1. cuts the clip at the playhead (snapped to a frame),
  2. removes the part before the playhead,
  3. moves the rest back to where the clip's space on its lane begins: the end of the previous clip on that lane, or 0:00,
  4. gives it a `0.3 s` fade-in (at most half its length), because it no longer starts at the beginning of the song. The fade-out at the end is kept.

  Then the remaining clip is selected, the playhead jumps to its start and playback starts (if that's inside the video), so the user hears the result with the video. Toast: "Music starts from m:ss.f" (the position in the song). Skipping an intro or using a part from the middle of a long song are both one tap.
- **MUS-10 Recent tracks:** the Music panel lists the **5 audio tracks used most recently, in any project**, newest first, under a "Recent" heading. Each row shows a music-note icon, the track's name, its length `m:ss` and a ＋. Tapping a row adds that track to the project like a new pick (`MUS-2` defaults) and closes the panel.
  - A track counts as used when it's added from Audio Tracks, From Video or Recent. Using one again moves it to the top. Two tracks are the same when the name and length (to `0.1 s`) match.
  - The app keeps its own copy of each recent track, so it still works after the project it was first used in is deleted (IMPLEMENTATION §4.1). The 6th oldest is dropped, with its copy.
  - Hidden when the list is empty.

---

## 12. Captions (CAP)

- **CAP-1 Generate:** Captions (main toolbar) with no captions yet shows "Transcribe speech into animated captions. Runs entirely on your device." and **Generate Captions**.
  - It transcribes the edit's speech on the device: clip sounds, voiceovers and extracted audio, never music or effects.
  - Busy: "Transcribing on device…". Toast: "Captioned N words".
  - The captions are then selected and the Style panel opens.
  - **Must never use server recognition.** If on-device recognition isn't available: "On-device speech recognition isn't available for this language." If speech recognition permission was refused: "Speech recognition permission is needed to create captions." If nothing was heard: "No speech was found in this video."
- **CAP-2 Splitting into captions:** words are grouped into captions of at most `5` words and `2.6 s`. A new caption starts after a pause over `0.55 s` or after `.`, `!` or `?`.
- **CAP-3 On screen:** one caption at a time, centred horizontally, at the chosen height. It stays up `0.25 s` past its last word. The word being spoken is the "active" word.
- **CAP-4 Style panel:**
  - **Styles:** **Classic · Karaoke (default) · Bold**.
  - **Highlight colour:** swatches; the default is yellow.
  - **Position:** a slider from `10`–`92%` of the height, default `78%`.
  - What the styles look like:
    - **Classic:** white text in a dark rounded box.
    - **Karaoke:** white text with a black outline and shadow; the active word is in the highlight colour.
    - **Bold:** uppercase condensed heavy font, outlined; the active word is highlighted.
  - In Karaoke and Bold, a newly active word pops slightly (4% for 0.12 s).
- **CAP-5 Edit** opens a full-screen "Edit Captions" editor:
  - **Layout:** **Cancel** and **Done** at the top. Each caption shows its time range ("0:03.0 – 0:04.6") above a multi-line text box.
  - **Starting point:** it opens on the caption at the playhead, or the last one before it, or the first. That caption is scrolled into view and the keyboard comes up on it. The caption being edited is highlighted in the accent colour.
  - **Above the keyboard:** the caption being typed in always stays visible above the keyboard.
  - **Navigation:** Return moves to the next caption. Tapping a time moves the playhead there.
  - **Saving:** typing only changes a draft. **Done** saves every change as **one** undo step. **Cancel** discards them. Closing must be instant; never save on every keystroke.
  - **Timing:** edited words are spread evenly over the caption's original time.
- **CAP-6 Fillers:** removes hesitation words from every caption: um, umm, ummm, uh, uhh, uhhh, ah, ahh, ahhh, er, err, erm, hmm, hm, mm, mmm.
  - **Matching:** ignores capital letters and punctuation around the word. Words that only contain these letters are kept, such as "umbrella" or "uh-huh".
  - **Tidying:** if a caption started with a removed filler, its new first word is capitalised. A comma left dangling at the end is removed.
  - **Timing:** the remaining words keep their times. Captions left empty are removed.
  - **Toasts:** "Removed N filler word(s)", or "No filler words found".
  - **Text only:** the video isn't cut.
- **CAP-7 Delete** removes all captions.
- **CAP-8 Older projects:** projects saved with the removed styles Minimal or Neon open as Classic or Karaoke respectively.

---

## 13. Export (EXP)

- **EXP-1 Options:**
  - **Resolution:** `720p`, `1080p` (default), `4K`. This is the short edge of the canvas.
  - **Frame rate:** `24`, `30` (default), `60` fps.
  - **Format:** `HEVC` (default), `H.264`.
  - **Readout:** the size and length, for example "720×1,280 · 0:12.0 · hardware encoded".
- **EXP-2 Estimated size:** shown before export. Formula in IMPLEMENTATION §11.
- **EXP-3 Buttons:**
  - **Export Video:** accent.
  - **Export & Share:** secondary. It exports, then opens the system share sheet straight away.
  - Below them: "Share to WhatsApp, Instagram, TikTok, Messages, AirDrop and more." Each platform lists its own sharing options.
- **EXP-4 While exporting:** a progress ring with a percentage. Close is disabled.
- **EXP-5 When done:**
  - The video plays in a player, unless Export & Share opened the share sheet.
  - "Exported in X.Xs · N MB".
  - **Save to Photos:** changes to "Saved". Platforms save to their gallery, or to Downloads/Movies on desktop.
  - **Share:** opens the system share sheet.
- **EXP-6 File name:** the exported file is named after the project, `<Project name>.mp4`, with characters not allowed in file names removed. If the name is empty: "Cutline Video".
- **EXP-7 Output:** an MP4 file with AAC audio. Preview and export are the same frame for frame (see `PRV-3` for animations).

---

## 14. Visual language

- **Colours:**
  - Background `#0E0E11`, surface `#1C1C20`, raised surface `#29292E`.
  - Accent (coral) `#FF3C61` (1.0, 0.235, 0.38). Soft accent: the accent at 18%.
  - Secondary text: white at 60%. Hairline borders: white at 8%.
- **Dark mode only.** Portrait only on phones; tablets use any orientation and desktop any window size (`LAY-4`).
- **Option chips:** a capsule, accent when selected, raised surface otherwise, white text. They report "selected" to accessibility tools.
- **Colour swatches** (shared by text, captions, cut-out): white, black, yellow (1, 0.86, 0.1), coral (1, 0.24, 0.38), blue (0.25, 0.55, 1), green (0.2, 0.8, 0.55), purple (0.65, 0.4, 0.95), orange (1, 0.55, 0.15).
- **Panels:** a title on the left and an accent ✓ button on the right that closes the panel.

---

## 15. Projects, saving and undo (PRJ)

- **PRJ-1 Autosave:** saves `0.4 s` after the last change, and on close. Writes are atomic: write to a temporary file, then rename.
- **PRJ-2 Undo:** up to `200` steps. Undo and redo show a toast ("Undo", "Redo"). A redo is lost after a new edit.
- **PRJ-3 Portable:** a project folder can be copied between devices and platforms and opens the same (IMPLEMENTATION §4).

---

## Platform parity

Keep this table current. ✅ = done, 🟡 = partly or differently (explain), ⬜ = not started, ⛔ = not possible on that platform (explain).

| Area | iOS | Android | macOS | Windows | Notes |
|---|---|---|---|---|---|
| Library LIB-1…5 | ✅ | 🟡 | ⬜ | ⬜ | Compose library + Photo Picker; Robolectric covers new project / samples |
| Timeline TML-1…13 | ✅ | 🟡 | ⬜ | ⬜ | Desktop: mouse wheel scrolls, ⌘/Ctrl+wheel zooms. Android has lanes, trim, TML-13 reorder |
| Clip editing CLP, SPD, REV, FRZ | ✅ | 🟡 | ⬜ | ⬜ | Split / Voice / Speed (SPD-4 Apply to all + SPD-5 re-timing) / Reverse / Freeze / Duplicate / Delete. Reverse uses windowed MediaCodec re-encode (falls back to a prepared copy when no encoder) |
| Denoise DNS | ✅ | 🟡 | ⬜ | ⬜ | DNS-1 panel + project-wide setting; §9.4 spectral NoiseReducer + JVM tests (hiss/tone/DNS-6); cleaned WAV as `nr2-…`; composition plays cleaned audio on a separate track |
| Filters, Adjust, Crop FLT, ADJ, CRP | ✅ | 🟡 | ⬜ | ⬜ | Exact formulas in core; panels wired; golden maths table still missing |
| Transitions and animation TRN, ANM | ✅ | 🟡 | ⬜ | ⬜ | Panels and model; transitions render as split halves (see CompositionBuilder) |
| Enhance ENH | ✅ | 🟡 | ⬜ | ⬜ | Pure maths AutoEnhance on device |
| Cutout CUT | ✅ | 🟡 | ⬜ | ⬜ | CUT-1 panel + §10.4 soft-edge / Transparent / Blur / Colour maths (unit-tested). Person-segmentation mask not fed into the live compositor yet |
| Reframe RFR | ✅ | 🟡 | ⬜ | ⬜ | FaceDetector path; no saliency fallback yet when no faces |
| Canvas, slides, watermark | ✅ | 🟡 | ⬜ | ⬜ | Intro/Outro/Watermark panels; fonts mapped to open substitutes |
| Text TXT | ✅ | 🟡 | ⬜ | ⬜ | Fonts: see IMPLEMENTATION §8.6 |
| Music MUS | ✅ | 🟡 | ⬜ | ⬜ | Audio Tracks / From Video / Recent / Cut / Start Here / Duck / Repeat; sample tracks in tests |
| Captions CAP | ✅ | 🟡 | ⬜ | ⬜ | CAP-1 Generate (demo captions in sample mode), Style / Edit / Fillers; real on-device speech recognition not wired yet |
| Export EXP | ✅ | 🟡 | ⬜ | ⬜ | Media3 Transformer + estimate/share; device-only encoding |
| Layouts LAY-1…8 | ✅ iPad | 🟡 | ⬜ | ⬜ | Phone portrait + Expanded (≥840 dp) sidebar; Robolectric covers both |

---

## Decisions and removed features

These were tried and removed on purpose. Don't add them back without changing this spec.

| Date | Decision |
|---|---|
| 2026-11 | **No volume control on music clips.** The music toolbar has no Volume, Fade or Duplicate. New music is always 70% volume with an automatic fade-out. Old projects keep their stored values. |
| 2026-11 | **Auto-duck is always on for new music**, and there's no on/off button. Only its level is adjustable (`MUS-5`). |
| 2026-11 | **No Volume tool on video clips.** A per-clip music/voice balance slider was built and then removed. Mute and Extract Audio were removed from the interface; projects that already used them still play as saved. |
| 2026-11 | **Voice on/off is back on video clips** (`CLP-5`), as a single toggle after Split. It sets the existing `isMuted` field; there's still no volume slider and no Extract Audio. |
| 2026-11 | **Caption styles are Classic, Karaoke and Bold.** Minimal and Neon were removed (`CAP-8`). |
| 2026-11 | **The caption text editor is full screen** and saves once on Done (`CAP-5`). Text editing isn't in the Style panel. |
| 2026-11 | **No scissors on the music bar.** It first showed under the playhead, then only on the selected bar, and was then removed: music is cut with **Cut** (and **Start Here**, `MUS-11`) in the toolbar (`MUS-4`). |
| 2026-11 | **No reorder menu on main-track clips.** A press-and-hold menu (Move to Start, Left, Right, End) was built and replaced by dragging in a thumbnail strip (`TML-13`), which works better with many clips. |
| 2026-11 | **Denoise is for the whole video, not per clip** (`DNS-1`). The per-clip Denoise button in the video clip toolbar was removed. Older per-clip settings still play until a level is picked (`DNS-8`). |
| 2026-11 | **No Media button in the main toolbar.** Media is added with the timeline "+", and a new project opens the Photos library (`LIB-1`). |
| 2026-11 | **The timeline "+" opens the Photos library directly**, with no Add menu, so video and photo files can't be picked from Files any more. Own audio still comes from Music → Audio Tracks. UI tests and demos (`-sampleMedia` / `-demoMedia`) still get the Add menu with Sample Clips. |
| 2026-11 | **No built-in music tracks in the Music panel.** It offers only Audio Tracks (Files) and From Video. The generator stays in the engine for UI tests and demos, which launch with `-sampleMedia` / `-demoMedia` and still see the tracks (§14 in IMPLEMENTATION). Projects that use them still play. |
| 2026-11 | **No landscape editor on phones.** Phones stay portrait only. Wide windows (iPad, Android tablets, desktop later) get the wide layout instead (`LAY-*`). |
| 2026-11 | **macOS is a separate app, built later.** It will reuse EditorKit and follow `LAY-*` for its window, but isn't the iPad app running on a Mac. |

### Engine features not exposed in the interface

These exist in the iOS engine and in older projects, but have no button. Other platforms must **play them correctly when a project contains them**, but don't need interface for them.

- **Audio sections:** markers that split a song into parts, each with its own volume or cut out (the older "Edit audio" editor).
- **Remove silences:** cuts long pauses out of speech, moving later text and captions to match.
- **Beat sync:** moves cuts onto the beats of the music.
- **Precise trim panel:** start and end sliders.
- **Older text animations:** `animationIn` and `animationOut`, used when a text has no `animation` set.
- **Extracted audio** on clips. (Muting is exposed as Voice, `CLP-5`.)

# Cutline: Occasion Templates (TPL)

**Status:** proposed, not built yet. Under review.
**Applies to:** iOS first (the reference), then Android, macOS and Windows. Everything here is meant to behave the same on every platform.
**Companion documents:** [FEATURES.md](FEATURES.md) (what the user sees), [IMPLEMENTATION.md](IMPLEMENTATION.md) (algorithms and file format), [project.sample.json](project.sample.json).

Templates turn a few photos and a name into a finished greeting video in under a minute: *Happy Birthday*, *Happy Anniversary*, *Welcome Baby*, and so on. A template is **data, not code**: a small JSON file that picks values for features the editor already has. These include opening and closing slides, photo motion, transitions, filters, text and canvas. The result is a **normal project** that the user can keep editing.

Following the usual process (IMPLEMENTATION §15.3), this document is reviewed first. When it's accepted, its user-facing parts move into FEATURES.md and its algorithms into IMPLEMENTATION.md (see §12). Then the iOS code follows.

---

## Contents

1. [Goals and non-goals](#1-goals-and-non-goals)
2. [Occasions and looks](#2-occasions-and-looks)
3. [User flow (TPL-1 … TPL-12)](#3-user-flow)
4. [Fields and placeholders](#4-fields-and-placeholders)
5. [Building the project](#5-building-the-project)
6. [Template file format](#6-template-file-format)
7. [The v1 looks, exactly](#7-the-v1-looks-exactly)
8. [Model additions](#8-model-additions)
9. [UI identifiers](#9-ui-identifiers)
10. [Tests](#10-tests)
11. [Platform notes](#11-platform-notes)
12. [Changes to the main spec when this is accepted](#12-changes-to-the-main-spec)
13. [Open decisions](#13-open-decisions)

---

## 1. Goals and non-goals

**Goals**
- A greeting video takes **four steps**: occasion, look, details, photos. Music is an optional fifth step.
- The result is an **ordinary, fully editable project**. Nothing about it is locked or "special".
- Templates use **only existing features**, so they look and export the same on every platform with no new rendering code. The one exception is the font on slides (§8).
- **Data-driven:** adding an occasion or a look means adding a JSON file, not writing code.
- **On the device only** (FEATURES §1). Templates are bundled with the app. Nothing is downloaded.

**Not in v1**
- Animated overlay effects (confetti, hearts, balloons, sparkles, fireworks). The format reserves a key for them (`effects`, §6.5) so they can be added later without breaking older apps.
- Built-in music. The spec currently says *no built-in music for users*; see [§13](#13-open-decisions) decision D1.
- Downloadable or user-made templates. Sharing templates between users is a later idea.
- Translated template text. v1 template strings are English. The format is ready for translations (§6.6).
- "Change look" after the project is made. The project remembers its template (§8.2) so this can be added later.

---

## 2. Occasions and looks

An **occasion** is what the video is for (Birthday). A **look** is one visual style for it (Party, Elegant). Each look is one template file.

### 2.1 v1 catalog (6 occasions × 2 looks = 12 templates)

| Order | Occasion id | Name | Icon (iOS SF Symbol / Android Material Symbol) | Looks |
|---|---|---|---|---|
| 1 | `birthday` | Birthday | `birthday.cake` / `cake` | `party` Party · `elegant` Elegant |
| 2 | `anniversary` | Anniversary | `heart.circle` / `favorite` | `classicGold` Classic Gold · `romantic` Romantic |
| 3 | `wedding` | Wedding | `sparkles` / `auto_awesome` | `elegantWhite` Elegant White · `cinematic` Cinematic |
| 4 | `newBaby` | New Baby | `figure.and.child.holdinghands` / `child_care` | `softPink` Soft Pink · `softBlue` Soft Blue |
| 5 | `graduation` | Graduation | `graduationcap` / `school` | `classic` Classic · `bold` Bold |
| 6 | `eid` | Eid Mubarak | `moon.stars` / `nights_stay` | `goldNight` Gold Night · `emerald` Emerald |

A template's id is `<occasion>.<look>`, for example `birthday.party`. The exact values for each look are in §7.

### 2.2 Backlog (later releases, same format)

| Group | Occasions |
|---|---|
| Life events | Engagement, Baby Shower, New Job / Promotion, Retirement, Housewarming, Farewell / Bon Voyage, Get Well Soon, In Loving Memory |
| Festivals and seasons | Ramadan Kareem, Christmas, New Year, Diwali, Valentine's Day, Mother's Day, Father's Day, Friendship Day, National Day |
| Personal | Congratulations, Thank You, Love / Just Because, Memories / Year in Review, Travel Recap, Sorry |

Adding one means adding its JSON files and a catalog entry (§6.1), then running the template contract test (§10.1).

---

## 3. User flow

### TPL-1 Entry
- The project library gets a second card under **New Project** (`LIB-1`): **Templates**, "Birthday, wedding, anniversary and more", with a `gift` icon.
- Tapping it opens the template flow full screen. Every step has **Back** (top left) and a step title. **Cancel** on the first step returns to the library.
- **Nothing is created until the last step** (TPL-9). Cancelling at any point leaves no project behind.

### TPL-2 Step 1: Occasion
- Title "Choose an occasion". A 2-column grid of tiles in catalog order. Each tile shows the occasion's icon, its name and its first look's slide colours as the tile background.
- Tapping a tile goes to step 2.

### TPL-3 Step 2: Look
- Title "Choose a look" with the occasion name as the subtitle.
- One card per look, vertically, showing a **live render of the look's opening slide** filled with the fields' sample values (§4.2), for example "Happy Birthday, Sarah!". The card is a square (1:1) slide with the look's name under it.
- Tapping a card selects it and goes to step 3.

### TPL-4 Step 3: Details
- Title "Add the details".
- At the top is a live preview of the opening slide. It updates as the user types, and empty fields use their sample values in a dimmed style.
- Below it is one input per field (§4.1), in template order. Required fields are marked "Required". Number fields use a number keypad, and date fields use the platform date picker.
- **Canvas** chips: `9:16` · `1:1` · `16:9`, preselected to the template's `canvas.aspectRatio`. (The other ratios, `3:4` and `4:5`, stay available later in the editor, `CNV-1`.)
- **Next** stays disabled until every required field has text. It then goes to step 4.

### TPL-5 Step 4: Photos
- Title "Pick photos & videos", with the hint from `media.hint`, for example "Best with 8–15 photos".
- **Pick** opens the system Photos library (the same picker as `IMP-1`: videos and photos, up to `20`). The picked order is the video's order.
- Cancelling the picker stays on this step. At least **1** item is required.
- When launched with `-sampleMedia` or `-demoMedia` (tests and demos), a **Sample Clips** button is also shown (IMPLEMENTATION §14).
- After picking, the flow goes to step 5.

### TPL-6 Step 5: Music (optional)
- Title "Add music", with the same sources as `MUS-1`:
  - **Audio Tracks** (Files) and **From Video**.
  - **Recent** (`MUS-10`), when there are any.
  - **No music**, a text button.
- Choosing any of these goes straight to TPL-7.

### TPL-7 Creating
- A busy overlay says "Creating your video…" with progress `n of N` while media is imported.
- If some items fail to import, they're skipped and the editor opens with a toast "Skipped N items".
- If **all** fail, the flow returns to step 4 with the message "Couldn't import the selected items".

### TPL-8 Result
- The editor opens with the new project, the playhead at `0:00` and nothing selected.
- A toast says "<Occasion> video ready · tap Play", for example "Birthday video ready · tap Play".
- The project is saved immediately and appears in the library like any other.

### TPL-9 One project, no undo past creation
- The built project is the session's **starting state**. Undo can't go back to an empty project, the same as opening an existing project.
- Everything the template set can be changed with the normal tools: Intro and Outro, Text, Filters, Animate, Duration, Transitions, Canvas and Music.

### TPL-10 Project name
- The project is named from the template's `projectName` alternatives (§4.4), for example "Sarah's Birthday".
- If no alternative can be filled, the occasion name is used, for example "Birthday".

### TPL-11 Empty-project rule
- A template project is never empty (it always has slides), so `LIB-4` doesn't delete it on close.

### TPL-12 Privacy
- The details typed in (names, dates, messages) are stored **only** inside that project, as baked-in slide and text content. They aren't remembered elsewhere, and nothing leaves the device (FEATURES §1).

---

## 4. Fields and placeholders

### 4.1 Field types

Each template declares the fields its form shows:

| Key | Meaning |
|---|---|
| `key` | Identifier used in placeholders. Letters and digits only, starting with a letter, for example `name`, `name2`, `years`. |
| `label` | Form label, for example "Name". |
| `type` | `text`, `number` or `date`. |
| `required` | `true` or `false`. |
| `maxLength` | `text` only: at most this many characters. Typing more isn't possible. Default `30`; messages use `80`. |
| `min`, `max` | `number` only: whole numbers in this range. Default `1…150`. |
| `default` | Optional starting value. For `number` and `date` the special value `"currentYear"` / `"today"` is allowed. |
| `sample` | **Required.** Shown in previews when the field is empty, for example `"Sarah"` or `30`. |
| `placeholderText` | Optional hint inside an empty text box, for example "Their first name". |

**Clean-up before use:** trim leading and trailing spaces, and collapse runs of whitespace (including new lines) to one space. A field that's empty after clean-up counts as **missing**.

### 4.2 Placeholders

- **Syntax:** template strings contain `{key}`, which is replaced by the field's value. Write `{{` and `}}` for literal braces.
- **Formats:** a suffix after `_` changes how a value is written:

| Placeholder | Field type | Result for value | Example |
|---|---|---|---|
| `{years}` | number | the number | `25` |
| `{years_ordinal}` | number | English ordinal | `25th` |
| `{date}` | date | **medium date in the device's locale** | `14 Nov 2026` (UK), `Nov 14, 2026` (US) |
| `{date_year}` | date | four-digit year | `2026` |
| `{name}` | text | the text | `Sarah` |
| `{name_possessive}` | text | English possessive | `Sarah's`; `James'` (ends in "s") |

- **English ordinals:** `1st 2nd 3rd 4th … 11th 12th 13th … 21st 22nd 23rd … 101st 111th`. If the number ends in 11, 12 or 13 the suffix is `th`; otherwise it's `st`, `nd` or `rd` for last digit 1, 2 or 3, and `th` for everything else.
- **Unknown placeholders** (a key or format that isn't defined) make the template **invalid**. The contract test fails (§10.1), so this never reaches users.

### 4.3 Alternatives (how missing optional fields are handled)

Every text in a template is a **list of alternatives**, tried in order:

```json
"title": ["Happy {years_ordinal} Anniversary", "Happy Anniversary"]
```

- The **first alternative whose placeholders are all filled** is used.
- If **none** can be filled:
  - a slide's `title` falls back to the occasion name (in practice the last alternative usually has no placeholders);
  - a slide's `subtitle` becomes empty;
  - a text overlay is **left out**.
- A plain string is allowed and means a list with one alternative.

### 4.4 Project name
`projectName` is a list of alternatives like any other (§4.3). If none fills, the name is the occasion name.

---

## 5. Building the project

Inputs: the template, the cleaned field values, the chosen aspect ratio, the imported media in picked order, and the music choice (or none).

1. **Resolve texts:** fill every alternative list (§4.3).
2. **Create the project:**
   - `name` from §4.4.
   - `aspectRatio`: the ratio chosen in TPL-4.
   - `background`: from `canvas.background`.
   - `defaultFit` and `defaultAnchor`: from `canvas.fit` and `canvas.anchor`.
   - `templateID`: the template's id (§8.2).
3. **Opening slide:** a title slide clip (`TTL-*`) with:
   - `placement: opening`, plus the resolved `title` and `subtitle`;
   - `background`, `accent`, `textColor`, `gradient` and `fontName` from the look's `slide` (§8.1);
   - length `opening.duration`;
   - `transitionOut` from `opening.transitionOut` (may be absent).
4. **Media clips**, one per imported item, in picked order:
   - **Photo:** length `media.photoDuration`. `photoMotion` is `media.photoMotions[i mod count]`, where `i` counts photos only, from 0.
   - **Video:** `sourceRange` runs from 0 to `min(file length, media.maxVideoSeconds)`. With `maxVideoSeconds` absent, the whole video is used.
   - **Every media clip:**
     - `filter` is `media.filter`, with `intensity`, when set.
     - `adjustments` aren't changed.
     - `animation` is `media.animation` when set.
     - `transitionOut` is `media.transitions[j mod count]`, where `j` counts media clips from 0. The last media clip's transition leads into the closing slide.
     - `isMuted` is `media.muteVideos` (default `false`). This is the `CLP-5` Voice flag.
   - **Canvas fit:** clips use the project's fit and anchor, as for `IMP-5`.
5. **Closing slide:** like the opening slide, with `placement: closing` and `closing.duration`. It's the last clip, so it never has a transition (`TRN-4`).
6. **Transition lengths:** each transition is clamped by the usual rule (`TRN-2`: never more than half of either clip).
7. **Text overlays:** for each entry in `texts` that resolves to text (§4.3):
   - **Time range** comes from `at` (see the table below), using the timeline layout *after* transitions (IMPLEMENTATION §6.1).
   - **Text and style:**
     - `text` is the resolved string.
     - `style` sets `fontName`, `size`, `color` and the optional `outlineColor` / `outlineWidth`, `shadow` and `backgroundColor`.
   - **Placement:** `anchor`, or `centerX` / `centerY` when no anchor is given.
   - **Animation:** `animation` (In / Out / Combo, the same set as `TXT-4`).
   - **Order:** overlays are added in template order, so later ones draw on top.

   | `at` | Start | Length |
   |---|---|---|
   | `firstMedia` | start of the first media clip + `offset` | `duration` |
   | `lastMedia` | start of the last media clip + `offset` | `duration` |
   | `allMedia` | start of the first media clip + `offset` | until the end of the last media clip, minus `offset` |
   | `closing` | start of the closing slide + `offset` | `duration` |

   The range is then clamped inside its anchor: inside `[first media start, last media end]` for the media anchors, and inside the closing slide for `closing`. `offset` defaults to `0` and `duration` to `3`. A range shorter than `0.5 s` after clamping drops the overlay.
8. **Music:** if a track was chosen, it's added exactly as `MUS-2` adds a new pick (start `0`, 70% volume, automatic fade-out, ducking on). The song runs past the video as usual (`MUS-3`); export stops at the end of the video.
9. **Start the session:** this project is the session's starting state (TPL-9). Save it, then open the editor (TPL-8).

**Determinism:** for the same template, field values, aspect ratio, media and music, every platform must produce the **same project**, apart from UUIDs and dates. §10.2 tests this.

---

## 6. Template file format

### 6.1 Where the files live

```
Templates/                      (repository root; shared by every platform)
    catalog.json                occasions in display order, and their looks
    birthday.party.json         one file per look
    birthday.elegant.json
    …
```

- **iOS** bundles the folder as a resource.
- **Android** copies it into `assets/Templates/` at build time. There must be no hand-edited copy.
- Files are **UTF-8 JSON**.
- **Times are in seconds** (decimal numbers), not MediaTime ticks, because people write these files by hand. Convert with `round(seconds × 60000)` ticks.
- **Colours** are `{"r","g","b"}` (and optionally `"a"`, default `1`), with values `0…1`, the same as `RGBAColor`.

`catalog.json`:

```json
{
  "formatVersion": 1,
  "occasions": [
    { "id": "birthday", "name": "Birthday",
      "icon": { "ios": "birthday.cake", "android": "cake" },
      "looks": ["birthday.party", "birthday.elegant"] }
  ]
}
```

### 6.2 Template file: complete example (`birthday.party.json`)

```json
{
  "formatVersion": 1,
  "id": "birthday.party",
  "occasion": "birthday",
  "name": "Party",
  "projectName": ["{name_possessive} Birthday", "Birthday"],
  "fields": [
    { "key": "name", "label": "Name", "type": "text", "required": true, "maxLength": 30,
      "sample": "Sarah", "placeholderText": "Their first name" },
    { "key": "age", "label": "Age", "type": "number", "required": false, "min": 1, "max": 150,
      "sample": 30 },
    { "key": "message", "label": "Message", "type": "text", "required": false, "maxLength": 80,
      "sample": "Wishing you the happiest day!" },
    { "key": "from", "label": "From", "type": "text", "required": false, "maxLength": 30,
      "sample": "Alex" }
  ],
  "canvas": { "aspectRatio": "9:16", "background": "blur", "fit": "fit", "anchor": "center" },
  "slide": {
    "background": { "r": 0.95, "g": 0.33, "b": 0.45 },
    "accent": { "r": 1, "g": 0.85, "b": 0.3 },
    "textColor": { "r": 1, "g": 1, "b": 1 },
    "gradient": true,
    "fontName": "ArialRoundedMTBold"
  },
  "opening": {
    "title": ["Happy Birthday, {name}!", "Happy Birthday!"],
    "subtitle": ["Turning {age} today", ""],
    "duration": 3,
    "transitionOut": { "kind": "zoom", "duration": 0.5 }
  },
  "media": {
    "hint": "Best with 8–15 photos",
    "photoDuration": 3,
    "maxVideoSeconds": 10,
    "photoMotions": ["zoomIn", "panRight", "zoomOut", "panLeft"],
    "transitions": [{ "kind": "zoom", "duration": 0.5 }],
    "filter": { "id": "punch", "intensity": 0.5 },
    "animation": null,
    "muteVideos": false
  },
  "texts": [
    { "text": ["{message}"], "at": "lastMedia", "offset": 0.3, "duration": 2.5,
      "anchor": "bottom",
      "style": { "fontName": "ArialRoundedMTBold", "size": 0.05,
                 "color": { "r": 1, "g": 1, "b": 1 },
                 "backgroundColor": { "r": 0, "g": 0, "b": 0, "a": 0.45 }, "shadow": false },
      "animation": { "entrance": "pop", "exit": "fade", "inDuration": 0.4, "outDuration": 0.4 } }
  ],
  "closing": {
    "title": ["Have an amazing day!"],
    "subtitle": ["With love, {from}", ""],
    "duration": 3
  },
  "music": { "mood": "upbeat" }
}
```

### 6.3 Keys

| Key | Required | Notes |
|---|---|---|
| `formatVersion` | yes | `1`. A reader skips templates with a higher version than it knows. |
| `id`, `occasion`, `name` | yes | `id` is `<occasion>.<look>` and is unique. |
| `projectName` | yes | Alternatives (§4.3). |
| `fields` | yes | 0 to 6 fields (§4.1). |
| `canvas.aspectRatio` | yes | `9:16`, `1:1` or `16:9` (the TPL-4 choices). |
| `canvas.background` | no | `"blur"` (default) or a colour object. |
| `canvas.fit`, `canvas.anchor` | no | The `defaultFit` / `defaultAnchor` values. Default `fit` / `center`. |
| `slide` | yes | Slide colours, `gradient` and `fontName` (one of the 8 font names in IMPLEMENTATION §8.6). |
| `opening`, `closing` | yes | `title` and `subtitle` alternatives, `duration` `1…10` (as `TTL-1`), and an optional `transitionOut` on `opening`. |
| `media.photoDuration` | yes | `0.5…30` (as `DUR-1`). |
| `media.maxVideoSeconds` | no | Absent means use the whole video. |
| `media.photoMotions` | yes | 1 or more `PhotoMotion` values. |
| `media.transitions` | yes | 0 or more `{kind, duration}`. An empty list means hard cuts. `kind` is a `TransitionKind`, and `duration` is `0.2…2` (`TRN-2`). |
| `media.filter` | no | `{id, intensity}`: a filter id from IMPLEMENTATION §8.4, with intensity `0…1`. |
| `media.animation` | no | A `ClipAnimation` (`entrance`, `exit`, `combo`, `inDuration`, `outDuration`). |
| `media.muteVideos` | no | Default `false`. |
| `media.hint` | no | Text for TPL-5. |
| `texts` | no | 0 to 4 overlays (§5 step 7). |
| `music.mood` | no | Hint only: `upbeat`, `romantic`, `calm`, `festive` or `cinematic`. Not used in v1 (D1). |

### 6.4 Validation (all must pass, checked by §10.1)
- The JSON parses, `formatVersion` is known, and `id` is unique and listed in `catalog.json` under its occasion.
- Every enum value is a known raw value: `PhotoMotion`, `TransitionKind`, `ClipEntrance`, `ClipCombo`, `OverlayAnchor` and aspect ratio.
- Every font name is one of the 8 in IMPLEMENTATION §8.6, and every filter id exists.
- Every number is in its range, and every colour component is in `0…1`.
- Every placeholder refers to a declared field with a format that matches its type (§4.2).
- Every field has a `sample`, and building with the samples alone gives a title that isn't empty.
- **Contrast:** each slide's text colour against its background has a WCAG contrast ratio of at least `4.5`.

### 6.5 Reserved for later
- `effects`: animated overlays (confetti, hearts and so on). Readers must **ignore** unknown keys (as IMPLEMENTATION §4.2 rule 2), so v1 apps still load templates that have them.
- `music.trackID`: a built-in track, if D1 allows them.

### 6.6 Translations (later)
A template may add `"localized": {"<language>": { <same text keys> }}`, for example `{"ar": {"opening": {"title": ["عيد مبارك"]}}}`. A reader uses the entry for the device language when it exists, and English otherwise. Not in v1.

---

## 7. The v1 looks, exactly

The `RGB` values below are `0…1`. **Fonts** use the UI names from IMPLEMENTATION §8.6:

| UI name | Font name |
|---|---|
| Bold | `HelveticaNeue-Bold` |
| Classic | `Georgia-Bold` |
| Rounded | `ArialRoundedMTBold` |
| Condensed | `Futura-CondensedExtraBold` |
| Elegant | `Didot-Bold` |
| Script | `SnellRoundhand-Black` |
| Heavy | `AvenirNext-Heavy` |

### 7.1 Fields per occasion

| Occasion | Fields (`key`: type, *required*, sample) |
|---|---|
| birthday | `name`: text, *required*, "Sarah" · `age`: number, "30" · `message`: text (80), "Wishing you the happiest day!" · `from`: text, "Alex" |
| anniversary | `name`: text, *required*, "Maria" · `name2`: text, *required*, "David" · `years`: number, "25" · `message`: text (80), "To many more years together" · `from`: text, "The Family" |
| wedding | `name`: text, *required*, "Emma" · `name2`: text, *required*, "Liam" · `date`: date, "today" · `message`: text (80), "Thank you for celebrating with us" |
| newBaby | `name`: text, *required*, "Noah" · `date`: date, "today" · `message`: text (80), "Welcome to the world, little one" · `from`: text, "Grandma & Grandpa" |
| graduation | `name`: text, *required*, "Aisha" · `school`: text (40), "Westfield High" · `year`: number (1900–2100, default "currentYear"), "2026" · `message`: text (80), "So proud of you!" |
| eid | `name`: text (recipient), "Ahmed" · `from`: text, "The Khan Family" · `message`: text (80), "May Allah bless you and your family" |

### 7.2 Texts per occasion (the same for both looks)

| Occasion | Project name | Opening title / subtitle | Message text (`at`) | Closing title / subtitle |
|---|---|---|---|---|
| birthday | "{name_possessive} Birthday" | "Happy Birthday, {name}!" / "Turning {age} today" | "{message}" (`lastMedia`, 0.3 s, 2.5 s) | "Have an amazing day!" / "With love, {from}" |
| anniversary | "{name} & {name2} Anniversary" | "Happy {years_ordinal} Anniversary" → "Happy Anniversary" / "{name} & {name2}" | "{message}" (`lastMedia`) | "Here's to many more years" / "With love, {from}" |
| wedding | "{name} & {name2} Wedding" | "{name} & {name2}" / "{date}" → "Just Married" | "{message}" (`closing`, 0.4 s, 2.2 s) | "Happily Ever After" / "{name} & {name2}" |
| newBaby | "Welcome {name}" | "Welcome, {name}!" / "Born {date}" | "{message}" (`firstMedia`, 0.3 s, 2.5 s) | "Welcome to the family" / "With love, {from}" |
| graduation | "{name_possessive} Graduation" | "Congratulations, {name}!" / "{school} · Class of {year}" → "Class of {year}" → "{school}" | "{message}" (`lastMedia`) | "The future is yours" / "Class of {year}" |
| eid | "Eid Mubarak" | "Eid Mubarak" / "To {name}, from {from}" → "From {from}" → "To {name}" | "{message}" (`lastMedia`) | "May this Eid bring you joy" / "{from}" |

Every subtitle list ends with `""`, so a subtitle whose fields are missing is simply left empty.

### 7.3 Look values

| Template | Slide bg / accent / text, gradient | Font | Canvas | Photo s | Motions (cycle) | Transitions | Filter | Clip animation |
|---|---|---|---|---|---|---|---|---|
| `birthday.party` | (0.95, 0.33, 0.45) / (1, 0.85, 0.3) / white, yes | Rounded | 9:16 | 3 | zoomIn, panRight, zoomOut, panLeft | zoom 0.5 | punch 0.5 | none |
| `birthday.elegant` | (0.07, 0.07, 0.09) / (0.85, 0.7, 0.4) / (0.98, 0.95, 0.88), yes | Elegant | 9:16 | 3.5 | kenBurns | dissolve 0.8 | golden 0.5 | none |
| `anniversary.classicGold` | (0.12, 0.09, 0.05) / (0.9, 0.75, 0.4) / (1, 0.96, 0.85), yes | Classic | 9:16 | 3.5 | kenBurns | dissolve 0.8 | golden 0.6 | none |
| `anniversary.romantic` | (0.45, 0.08, 0.18) / (1, 0.6, 0.7) / white, yes | Script | 9:16 | 3.5 | zoomIn, zoomOut | fade 0.7 | rose 0.6 | none |
| `wedding.elegantWhite` | (0.97, 0.96, 0.93) / (0.78, 0.65, 0.45) / (0.15, 0.13, 0.12), no | Elegant | 9:16 | 4 | kenBurns | dissolve 1.0 | matte 0.5 | none |
| `wedding.cinematic` | black / white / white, no | Classic | 16:9 | 4 | panLeft, panRight | fade 0.8 | teal_orange 0.7 | none |
| `newBaby.softPink` | (0.98, 0.86, 0.89) / (0.95, 0.45, 0.6) / (0.35, 0.15, 0.25), no | Rounded | 9:16 | 3 | zoomIn | fade 0.6 | pastel 0.5 | none |
| `newBaby.softBlue` | (0.86, 0.92, 0.98) / (0.35, 0.6, 0.95) / (0.12, 0.2, 0.35), no | Rounded | 9:16 | 3 | zoomIn | fade 0.6 | pastel 0.5 | none |
| `graduation.classic` | (0.05, 0.1, 0.25) / (0.95, 0.78, 0.3) / white, yes | Classic | 9:16 | 3 | kenBurns | slideLeft 0.5 | vivid 0.4 | none |
| `graduation.bold` | (0.06, 0.06, 0.06) / (1, 0.24, 0.38) / white, yes | Heavy | 9:16 | 2.5 | zoomIn, zoomOut | zoom 0.4 | punch 0.5 | In: pop 0.4 |
| `eid.goldNight` | (0.04, 0.07, 0.18) / (0.95, 0.78, 0.35) / (1, 0.95, 0.8), yes | Elegant | 9:16 | 3.5 | kenBurns | dissolve 0.8 | golden 0.4 | none |
| `eid.emerald` | (0.03, 0.25, 0.18) / (0.95, 0.85, 0.5) / white, yes | Classic | 9:16 | 3.5 | kenBurns | dissolve 0.8 | warm 0.4 | none |

**Shared by all v1 looks:**
- Opening and closing slides are `3 s`; the opening `transitionOut` is the look's first transition.
- `maxVideoSeconds` is `10` and `muteVideos` is `false`. The canvas uses `blur` with fit `fit` / `center`.
- The message overlay:
  - uses the look's font at size `0.05`, white, on a black label at 45%, with no shadow, at anchor `bottom`;
  - pops in and fades out over `0.4 s`;
  - **on light looks** (`wedding.elegantWhite`, `newBaby.*`) the colours swap: text in the slide's text colour on a white label at 70%.

**Music mood hints:**

| Template | Mood |
|---|---|
| `birthday.party`, `graduation.bold` | upbeat |
| `anniversary.*`, `wedding.elegantWhite` | romantic |
| `wedding.cinematic` | cinematic |
| `newBaby.*` | calm |
| `birthday.elegant`, `graduation.classic`, `eid.*` | festive |

---

## 8. Model additions

Both additions are **optional fields** (IMPLEMENTATION §4.2 rule 3), so older apps and other platforms still open the projects.

### 8.1 `TitleCard.fontName: String?`
- The PostScript name of the slide **title** font. When absent, it's `HelveticaNeue-Bold`, which is today's behaviour.
- The subtitle stays HelveticaNeue-Medium.
- The renderer (IMPLEMENTATION §8.9) uses this font for the title at the same size (`0.075 × side`). If a long title doesn't fit, it shrinks in steps of `0.005 × side` down to `0.05 × side`, then wraps.
- **TTL panel:** editing a template slide keeps its `fontName`. Picking a colour preset changes colours only. There's no font picker on slides in v1.
- **Cross-platform:** the same font mapping as text overlays (IMPLEMENTATION §8.6).

### 8.2 `Project.templateID: String?`
- The id of the template the project was made from, for example `"birthday.party"`. It's absent for normal projects.
- It isn't shown and has no effect in v1. It allows a later "Change look" and keeps the information local (TPL-12).

When built, regenerate `project.sample.json` with both fields set (AGENTS.md rule 3).

---

## 9. UI identifiers

These are the same strings on every platform: accessibility identifiers on iOS, test tags on Android.

| Element | Identifier |
|---|---|
| Library card | `library.templates` |
| Occasion tile | `template.occasion.<occasionID>` |
| Look card | `template.look.<templateID>` |
| Field input | `template.field.<key>` |
| Canvas chip | `template.ratio.<ratio>`, for example `template.ratio.9:16` |
| Next / Back / Cancel | `template.next` / `template.back` / `template.cancel` |
| Pick media / Sample clips | `template.pick` / `template.sampleClips` |
| Music sources | `template.music.files`, `template.music.fromVideo`, `template.music.recent.<n>`, `template.music.none` |
| Slide preview | `template.preview` |

---

## 10. Tests

### 10.1 Template contract test (every platform)
- Load `catalog.json` and every template, then check every rule in §6.4.
- Build every template with its **sample values** and a fixed fixture set: 3 photos and 1 video of 15 s, in the order photo, video, photo, photo. The build must succeed with:
  - 6 clips (opening, the 4 media clips and closing);
  - text overlays inside the project's length;
  - a title that isn't empty.

### 10.2 Golden build (every platform)
- Build `birthday.party` and `anniversary.classicGold` from fixed values and the fixture media, with ratio `9:16` and no music.
- Compare the result with `docs/spec/templates/<id>.expected.json` **after normalising**: remove `id`, `mediaID`, `createdAt`, `modifiedAt` and file names, then compare key by key with times as ticks.
- iOS writes these expected files. Other platforms must match them.

### 10.3 Unit tests (core)
Prefix the test names with `TPL-n`:

| Area | Cases |
|---|---|
| Placeholders | Ordinals 1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 101, 111 and 112; possessives "Sarah's" and "James'"; `{{` braces; dates in en-US and en-GB |
| Alternatives | The first filled alternative wins; the subtitle becomes `""`; the overlay is left out; the project name falls back to the occasion name |
| Build | Clip order; photo durations; motion cycling over photos only; transition cycling; no transition on the closing slide; video capped at `maxVideoSeconds` |
| Filter and animation | Applied to media clips only, not slides |
| Overlay timing | Each `at` value; clamping; dropped when shorter than 0.5 s |
| Model | `templateID` is set; `fontName` is set on both slides |
| Session | Undo history is empty after building (TPL-9) |
| Music | Added with the `MUS-2` defaults when chosen, and no audio clips with "No music" |

### 10.4 UI test (iOS first, then each platform)
`TPL-1…8 test22_TemplateBirthday`, launched with `-sampleMedia`:
1. Tap the Templates card, then `template.occasion.birthday`, then `template.look.birthday.party`.
2. Type "Sarah" and check the preview says "Happy Birthday, Sarah!".
3. Next, then Sample Clips, then No music.
4. In the editor, check the clip count is 2 + the media count, that the toast contains "Birthday video ready", and that the project name is "Sarah's Birthday".
5. Close the editor and check the library lists it.

Then check that Cancel at step 3 creates nothing.

---

## 11. Platform notes

- **Same files, same result.** Every platform reads the same `Templates/` folder, and the golden test (§10.2) holds them to one result.
- **Android:**
  - Material 3 screens with the same steps, the same order and the same strings.
  - Use a `HorizontalPager` or a navigation graph for the steps, and handle system Back per step.
  - Use the Photo Picker for TPL-5 (`PickMultipleVisualMedia(20)`).
  - Draw the slide preview with the same slide renderer as export (no separate drawing code), so the preview equals the result.
- **Fonts:** the slide `fontName` uses the same mapping table as text (IMPLEMENTATION §8.6). Bundling the open fonts listed there is strongly recommended before templates ship on Android, because Script and Elegant matter most here.
- **Desktop (later):** the same flow in a centred window. TPL-5 uses the system file picker for images and videos.

---

## 12. Changes to the main spec

When this proposal is accepted, before or with the iOS code:

**FEATURES.md**
- A new section **"TPL: Occasion templates"** with TPL-1 … TPL-12 (§3 above, condensed).
- `LIB-1` mentions the Templates card under New Project.
- A glossary row: **Template**, a ready-made style for an occasion that builds a normal project from photos and a few details.
- A parity table row: `Templates TPL-1…12 | ⬜ | ⬜ | ⬜ | ⬜ | Same JSON files in Templates/`.
- A Decisions entry for whatever is decided for D1 (music).

**IMPLEMENTATION.md**
- §3.1 gets `templateID`, and the TitleCard fields get `fontName`.
- §4.1 describes the `Templates/` folder.
- §8.9 covers the title font and the shrink-to-fit rule.
- A new section **"Templates"** with §4–§6 of this document.
- §15.1 lists the template contract and golden tests.

**docs/android/README.md**
- A milestone row **M9 Templates (`TPL-*`)** after M5 (it needs slides, text, filters, transitions and animation).
- An item under *Tests to port first* for the template contract and golden tests.

---

## 13. Open decisions

| # | Question | Proposal in this draft | Alternatives |
|---|---|---|---|
| D1 | **Music.** The spec says no built-in music for users. Templates feel bare without music. | Keep the rule. Step 5 offers Audio Tracks, From Video, Recent or No music. `music.mood` is stored for later. | (a) Allow the on-device generated tracks **only inside templates**, picked by mood. (b) Add new mood-based generated tracks for templates. |
| D2 | **v1 occasions** | Birthday, Anniversary, Wedding, New Baby, Graduation and Eid (12 looks). | Swap Eid for Christmas or New Year, or ship fewer looks. |
| D3 | **Effects** (confetti, hearts) | Not in v1. The `effects` key is reserved. | Add a small set of particle overlays in v1. That needs new rendering in IMPLEMENTATION §8 and on every platform. |
| D4 | **Canvas choices in TPL-4** | `9:16`, `1:1` and `16:9`. | All 5 ratios. |
| D5 | **Where Templates appears** | A card under New Project on the library. | A toggle on New Project ("Blank / From template"), or a tab. |
| D6 | **Language** | English template text in v1. The format is ready for translations (§6.6). | Ship Arabic and others with v1, which matters for Eid. |

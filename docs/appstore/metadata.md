# App Store submission: Cut & Weld

Everything to paste into App Store Connect for the first iOS release. Character limits are Apple's; counts were checked with a script.

## App Information

| Field | Value |
|---|---|
| Name | Cut & Weld: Video Editor |
| Subtitle | Trim, join, caption & music |
| Bundle ID | `com.mujassir.cutnweld` (locked after the first build upload) |
| SKU | `ncut-ios-001` (already set, cannot change) |
| Primary language | English (U.S.) |
| Primary category | Photo & Video |
| Secondary category | Entertainment |
| Content rights | Does not contain, show or access third-party content (set 2026-11-25; it had not been saved before) |
| Age rating | 4+ (set: "No" or "None" to every question) |

## Version 1.0.0

### Promotional text (max 170, can be changed without review)

Edit videos right on your iPhone or iPad. Auto captions, music that ducks under voices, speed, filters and AI tools, all on device. No account, no uploads, no watermark.

### Description (max 4000)

Cut & Weld is a fast, private video editor. Trim, join and polish your clips, add music and animated captions, and export in up to 4K. Everything runs on your device: no account, no uploads, no watermark.

CUT AND JOIN
• Split, trim, duplicate and reorder clips on a clear timeline
• Speed from 0.1× to 10×, reverse and freeze frames
• 8 transitions and in, out and combo animations
• Photos with adjustable duration and gentle motion

CAPTIONS THAT WRITE THEMSELVES
• Transcribe speech into animated captions on device
• Classic, Karaoke and Bold styles with a highlight colour
• Edit the text, and remove filler words in one tap

MUSIC THAT SITS RIGHT
• Add your own audio or the sound from another video
• Music dips automatically while someone is speaking
• Start a song from any point, cut it or repeat it to the end

LOOK GREAT
• 20 filters and adjust sliders for light and colour
• Auto Enhance fixes brightness, contrast and colour
• Remove the background from people
• Auto Reframe follows faces so wide shots fit a vertical video
• Noise reduction for clearer voices
• Crop, rotate and flip

MAKE IT YOURS
• Text with fonts, colours and animation
• Opening and closing slides
• Your own text or image watermark, only if you want one
• 9:16, 4:5, 1:1, 3:4 and 16:9 canvases with a blurred or solid background

EXPORT AND SHARE
• 720p, 1080p or 4K at 24, 30 or 60 fps, in HEVC or H.264
• See the file size before you export
• Save to Photos or share to your favourite apps, Messages and AirDrop

PRIVATE BY DESIGN
Your videos never leave your device. Editing, AI features, captions and export all happen on your iPhone or iPad. Projects save automatically, and every change can be undone.

### Keywords (max 100, comma-separated, no spaces)

split,speed,subtitles,filters,transitions,reverse,reframe,montage,clip,vlog,slideshow,merge,4k,fx

No trademarked app names (Guideline 2.3.7): `tiktok`, `reels` and `shorts` were removed on 2026-11-25.

### URLs

| Field | Value |
|---|---|
| Support URL | https://mujassir.github.io/video-editor/ (set) |
| Marketing URL | Not used |
| Privacy Policy URL | https://mujassir.github.io/video-editor/privacy.html (set, on the App Privacy page) |

Both pages are GitHub Pages served from the `gh-pages` branch. Their source is in `docs/appstore/site/`. To update them, change the files there and push them to `gh-pages` again.

### Copyright

2026 Mujassir Nasir

### What's New

Not shown for the first version.

## App Privacy

Answer **"No, we do not collect data from this app."** That gives the "Data Not Collected" label. It's accurate: the app has no network code, no analytics and no third-party SDKs (AGENTS.md rule 4), and `App/PrivacyInfo.xcprivacy` declares no tracking and no collected data.

## Privacy policy (to host)

> **Cut & Weld privacy policy**
>
> Cut & Weld does not collect, store or share any personal data. All editing, speech recognition, AI features and video export happen on your device. Your photos, videos, audio and projects are never uploaded and stay on your device unless you choose to share an exported video.
>
> The app asks for permission to read your photo library (to import media), add to it (to save exports), and use speech recognition (to create captions on device). You can change these permissions at any time in Settings.
>
> The app contains no advertising, analytics or tracking. Contact: <your support email>.

## App Review Information

| Field | Value |
|---|---|
| Sign-in required | No |
| Contact | Your name, phone and email |
| Notes | The full six-point answer in `review-notes.md` (set 2026-11-25). Attach a screen recording too, see `review-readiness.md` |

## Export compliance

`ITSAppUsesNonExemptEncryption` is `NO` in the Info.plist, so App Store Connect won't ask about encryption on each build.

## Screenshots

Generated with `tools/screenshots/capture.sh build/appstore-screenshots`. It renders original footage (`tools/screenshots/make-footage.swift`), then `AppStoreScreenshotUITests` drives the app on the iPhone 17 Pro Max and iPad Pro 13-inch simulators, with the status bar set to 9:41.

| Order | File | Shows |
|---|---|---|
| 1 | `*-01-editor.png` | Editor with clips, music and a Karaoke caption on the video |
| 2 | `*-02-captions.png` | Caption styles |
| 3 | `*-03-filters.png` | Filters |
| 4 | `*-04-speed.png` | Speed |
| 5 | `*-05-export.png` | Export options and size estimate |

iPhone files are 1320 × 2868 (6.9" display), iPad files are 2064 × 2752 (13" display). No alpha channel.

App Store Connect's iPhone slot now asks for the 6.1"/6.3" size, so upload the 1206 × 2622 copies in `build/appstore-screenshots/iphone-6.3/`. iPad uses the originals.

The App Store icon comes from the build: build 2 is attached to version 1.0.0, and its App Icon shows under Included Assets.

## Availability

Set in App Store Connect on 2026-11-24: **147 countries or regions**. Not available in **China mainland** or the **27 EU countries** (Austria, Belgium, Bulgaria, Croatia, Cyprus, Czech Republic, Denmark, Estonia, Finland, France, Germany, Greece, Hungary, Ireland, Italy, Latvia, Lithuania, Luxembourg, Malta, Netherlands, Poland, Portugal, Romania, Slovakia, Slovenia, Spain, Sweden). Non-EU Europe (UK, Norway, Switzerland, Iceland and others), Hong Kong, Macao and Taiwan stay available.

**Price:** Free (base country United States).

**Platforms:** iPhone and iPad only. "Make this app available" for Apple silicon Macs and Apple Vision Pro are both off.

## TestFlight

- Build **1.0.0 (1)** uploaded 2026-11-24 (had ITMS-91306: Metal shader source in the release build). **1.0.0 (2)** uploaded the same day with `MTL_ENABLE_DEBUG_INFO: NO` for Release, which fixes it.
- Internal group **Internal Testers** with automatic distribution: every new build goes to its testers without review.
- Not submitted for App Review.
- To upload the next build, raise `CURRENT_PROJECT_VERSION` in `project.yml` first (build numbers must go up).

# App Review readiness: Cut & Weld 1.0.0

Checked on 2026-11-25 against the App Review Guidelines, the App Store Connect setup and the code.

## Lesson from Cassette 1.0.0's first review

Cassette 1.0.0 wasn't rejected for a bug. Apple paused the review with **Guideline 2.1 – Information Needed** (Nov 23, 2026) and asked for six things in the review notes before it would continue:

1. A screen recording on a physical device running the latest iOS. It has to start by launching the app and show the typical flow, plus any login, account deletion, user-generated content moderation or paid content.
2. The app's purpose and target audience: the problem it solves and the value it gives.
3. Setup instructions for the main features, with login details or sample files if needed.
4. The external services, tools or platforms the app uses (data, authentication, payments, AI).
5. Any regional differences, or confirmation that it works the same everywhere.
6. Documents for regulated industries or third-party material, if any apply.

The notes Cassette was submitted with were a short "how to test" paragraph, with no recording and nothing on purpose, services or regions. After the six answers and a recording were added, it was approved.

**What to do differently:** answer all six points in the notes and attach the recording on the **first** submission. Apple now asks for these on new apps, and an incomplete answer costs a full review round, usually one to two days.

Apple's message also listed these common issues to check: bugs and crashes on real devices (2.1), demo login details (2.1), screenshots that show the real app in use (2.3.3), in-app purchases submitted with the app (3.1.1), and apps meant only for one business (3.2).

## Checklist

| Area | Guideline | Status |
|---|---|---|
| Review notes answer all six 2.1 points | 2.1 | **Done.** In App Store Connect, from `review-notes.md` |
| Screen recording on a real device, attached | 2.1 | **To do (you).** See below |
| Build tested on real iPhone and iPad | 2.1 | **To do (you).** Use TestFlight build 1.0.0 (2) |
| iPhone screenshots | 2.3.3 | **To do (you).** Slot is empty. Drag in `build/appstore-screenshots/iphone-6.3/` (1206 × 2622) |
| iPad 13" screenshots | 2.3.3 | **To do (you).** Slot is empty. Drag in `build/appstore-screenshots/ipad-0*.png` (2064 × 2752) |
| Screenshots show the real app in use | 2.3.3 | OK. Generated from the app by UI tests |
| No trademarked app names in keywords | 2.3.7 | **Fixed.** Removed `tiktok`, `reels` and `shorts` |
| No third-party app names in the description | 2.3.7 | **Fixed.** "share to WhatsApp, Instagram, TikTok…" became "share to your favourite apps, Messages and AirDrop" |
| App Privacy answers published | 5.1.1 | **To do (you).** "Data Not Collected" is answered but not published. Click **Publish** on App Privacy |
| Privacy policy URL works | 5.1.1 | OK (HTTP 200) |
| Support URL works | 1.5 | OK (HTTP 200) |
| Content Rights | 5.2 | **Fixed.** Was not set. Now "does not contain, show or access third-party content" |
| Age rating | 1.3 | OK. 4+ |
| Permission prompts explain their use | 5.1.1 | OK. Photos, Photos (add) and Speech Recognition strings are clear and specific |
| No unused permissions | 5.1.1 | OK. No camera, microphone or location use in the code |
| Privacy manifest | 5.1.2 | OK. No tracking and no data collected. The app uses no required-reason APIs (`attributesOfItem` reads only `.size`) |
| No network, SDKs or server AI | 2.5.2, 5.1 | OK. The only URLSession call is the App Store update check (`App/UpdateChecker.swift`, app ID and country code). No third-party code. Speech is forced on-device |
| Encryption declaration | Export | OK. `ITSAppUsesNonExemptEncryption = NO` |
| No in-app purchases or ads | 3.1.1 | OK. Free with nothing to buy |
| Availability | — | OK. 147 regions (no China mainland or EU), iPhone and iPad only, Mac and Vision Pro off |
| App Compliance (China, DSA) | — | Not needed. The app isn't offered in China mainland or the EU |
| Release option | — | Manual release is selected. Switch to automatic if it should go live as soon as it's approved |

## Screen recording: what to record

On a real iPhone, open Control Center → Screen Recording, then:

1. Start from the Home Screen and open Cut & Weld.
2. Tap **New Project**, allow Photos and pick two or three videos, including one with someone speaking.
3. Trim a clip, split it, change its speed and apply a filter.
4. **Captions → Generate Captions** (allow Speech Recognition) and switch caption styles.
5. **Music → Audio Tracks**, then add a song.
6. **Export → Export Video**, then show the video saved in Photos.

Stop the recording, AirDrop it to the Mac, rename it with a lowercase `.mp4` extension, and drag it onto **Attachment** under App Review Information. App Store Connect rejects an uppercase `.MP4`.

## Optional

- The Export screen and screenshot 5 still say "Share to WhatsApp, Instagram, TikTok, Messages, AirDrop and more". This is descriptive and usually accepted, but a strict reviewer can flag third-party names under 2.3.7. Changing it to "Share to your favourite apps, Messages, AirDrop and more" removes the risk. That needs a new build and a new screenshot.

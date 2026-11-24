# App Review notes: Cut & Weld 1.0.0

Paste everything between the lines into App Store Connect → iOS App 1.0.0 → App Review Information → Notes. It answers, up front, the six points Apple asks for under Guideline 2.1 (Information Needed), which held up Cassette's first review.

---

1. SCREEN RECORDING
Attached in the App Review attachments: recorded on a physical iPhone running the latest iOS. It starts by launching Cut & Weld from the Home Screen and shows the typical flow: New Project, picking videos, trimming and splitting, speed, filters, generating captions, adding music, and exporting to Photos. Cut & Weld has no accounts, no user-generated content shared with others, and no paid content or in-app purchases.

2. PURPOSE AND TARGET AUDIENCE
Cut & Weld is a video editor for people who make short videos on their iPhone or iPad, such as social clips, family videos and vlogs, and want to edit privately without an account, subscription, watermark or uploading their footage. It solves the common problem of needing several apps (or a desktop) to trim, caption, add music and export a video: everything is in one app and runs on the device.

3. SETUP AND MAIN FEATURES
No login or account is needed, and no sample files are required: any videos or photos in the device's Photos library work. For captions, use a video with someone speaking (for example, record a few seconds of yourself talking with the Camera app).
a) Tap New Project and pick one or more videos or photos (allow Photos access when asked).
b) Tap a clip on the timeline for clip tools: Split, Speed, Filters, Adjust, Crop, Freeze and more. Drag clip edges to trim.
c) Tap Captions, then Generate Captions (allow Speech Recognition). Captions appear on the video; try the Classic, Karaoke and Bold styles.
d) Tap Music, then Audio Tracks to add a song from Files, or From Video to use the sound of another video.
e) Tap Export, choose resolution and frame rate, then Export Video to save to Photos, or Export & Share.

4. EXTERNAL SERVICES
None. Cut & Weld makes no network requests and includes no third-party SDKs, analytics, advertising, accounts, payments or server-side AI. Every feature runs on the device using Apple frameworks: AVFoundation (editing and export), Core Image and Metal (filters and effects), Vision (background removal and face-following reframe) and Speech (captions, with on-device recognition only). On first use of captions, iOS may download its on-device speech model from Apple; the app itself sends nothing anywhere.

5. REGIONAL DIFFERENCES
None. The app works the same in every region where it is available. Caption generation depends on iOS supporting on-device speech recognition for the device's language; if it doesn't, the app shows a message and every other feature still works.

6. REGULATED INDUSTRY / THIRD-PARTY MATERIAL
Not applicable. Cut & Weld ships with no music, video or other third-party content; it edits only media the user already has on the device.

Permissions: Photos (import media and save exports) and Speech Recognition (captions). The app doesn't use the camera, microphone or location.
Privacy policy: https://mujassir.github.io/video-editor/privacy.html

---

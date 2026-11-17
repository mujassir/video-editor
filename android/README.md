# Cutline for Android

## Open in Android Studio

1. Pull the branch: `git fetch origin && git checkout claude/android-app`
2. In Android Studio choose **File → Open…** and select this `android/` folder (not the repository root).
3. Let Gradle sync. Android Studio creates `local.properties` with your SDK path; it isn't committed.
4. Pick the **app** run configuration and a phone or emulator (Android 8.0 / API 26 or newer), then Run.

Android projects have no separate project file (like `.xcodeproj`): the Gradle files are the project.

Requirements: Android Studio with JDK 17+, Android SDK 36 (Studio offers to install it).

## Modules

- `core`: pure Kotlin model, editing, undo, storage, render maths. `./gradlew :core:test`
- `engine`: Media3 import, preview composition, GL renderer, export.
- `app`: Compose UI. Phones are portrait only; tablets use the wide layout.

See `docs/android/README.md` and `docs/spec/` for the spec this app follows.

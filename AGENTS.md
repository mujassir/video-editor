# Guide for AI agents and contributors

Cutline will ship on iOS (this repo, the reference), then Android, macOS and Windows. The apps must behave the same everywhere.

**Starting the Android app?** Begin with [docs/android/README.md](docs/android/README.md): the stack, module layout, iOS → Android map, milestones, tests to port and known pitfalls.

**Before changing behaviour, read:**
- [docs/spec/FEATURES.md](docs/spec/FEATURES.md): what the user sees. Every feature has an ID (`MUS-4`, `CAP-5`, …).
- [docs/spec/IMPLEMENTATION.md](docs/spec/IMPLEMENTATION.md): exact algorithms, numbers, formulas and the file format.
- [docs/spec/project.sample.json](docs/spec/project.sample.json): the shared project file, checked by `ProjectFileContractTests`.

**Rules:**
1. **The spec decides.** If code and spec disagree, raise it; don't silently pick one. Change the spec first, then the code.
2. **Removed features stay removed.** See *Decisions and removed features* in FEATURES.md before adding a control, for example music volume, video Volume, Mute, or the Minimal or Neon caption styles.
3. **Model changes are additive.** New fields are optional, so older projects and other platforms still open them. Regenerate `project.sample.json` (delete it and run the contract test) and commit it.
4. **On-device only.** No network, no server AI fallback, no third-party SDKs that phone home. The one exception is `App/UpdateChecker.swift`: at most once a day it asks Apple's App Store lookup service for the latest version (app ID and country code only) to offer an update. Don't send anything else, and don't add other requests.
5. **Put the feature ID** in test names and pull request titles, and update the parity table in FEATURES.md.

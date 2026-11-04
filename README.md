# video-editor
A powerful video editing app to trim, merge, enhance, and transform videos with professional tools and creative effects.

## Open in Xcode

Requires Xcode 26+ (the app targets iOS 26, iPhone 15 and newer).

```bash
open Cutline.xcodeproj
```

Pick the **Cutline** scheme and an iPhone simulator, then Run (⌘R). To run on your iPhone, set your
**Team** under *Signing & Capabilities* for the **Cutline** target (and change the bundle ID if needed).

The project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen).
After adding files or editing `project.yml`, regenerate it:

```bash
brew install xcodegen
xcodegen generate
```

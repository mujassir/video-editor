import XCTest

/// App Store screenshots. Skipped unless SCREENSHOT_DIR is set (tools/screenshots/capture.sh sets it).
/// Uses the generated footage from tools/screenshots/make-footage.swift (DEMO_MEDIA) and ready-made captions.
final class AppStoreScreenshotUITests: CutlineUITestCase {
    override var useDemoMedia: Bool { true }
    override var extraLaunchArguments: [String] { ["-sampleCaptions"] }

    private var folder: URL?

    private func shot(_ name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))   // let animations and thumbnails settle
        snapshot(name)
        guard let folder else { return }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: folder.appendingPathComponent("\(device)-\(name).png"))
    }

    /// Tapping the selected item again clears the selection and brings back the main tools.
    private func deselect(_ id: String) {
        if element("tool.Music").exists { return }
        element(id).tap()
        // Fallback (TML-5): tapping empty timeline space deselects.
        for dy in [0.6, 0.15, 0.95] where !element("tool.Music").waitForExistence(timeout: 2) {
            element("timeline").coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: dy)).tap()
        }
        if !element("tool.Music").exists { shot("debug-\(id)") }
        XCTAssertTrue(element("tool.Music").waitForExistence(timeout: 5), "main tools after deselecting \(id)")
    }

    func testAppStoreScreenshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !dir.isEmpty else {
            throw XCTSkip("SCREENSHOT_DIR not set")
        }
        folder = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder!, withIntermediateDirectories: true)
        executionTimeAllowance = 900

        openProjectWithSamples(expectedClips: 3)
        waitFor("captions on the timeline") { count(prefix: "caption.") >= 4 }

        // Clean caption text: drop the filler words the sample captions contain.
        element("caption.0").tap()
        tap("tool.Fillers")
        waitFor("fillers removed") { count(prefix: "caption.") == 3 }
        deselect("caption.0")

        // Music under the video.
        tap("tool.Music")
        tap("music.use.sunrise")
        waitUntilIdle()
        waitFor("music lane") { count(prefix: "audio.") == 1 }
        deselect("audio.0")

        // Playhead on the second caption.
        let tl = element("timeline").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        tl.press(forDuration: 0.05, thenDragTo: tl.withOffset(CGVector(dx: -110, dy: 0)))
        RunLoop.current.run(until: Date().addingTimeInterval(3))   // let the "Added …" toast fade
        print("SCREENSHOT PLAYHEAD \(element("time.current").label)")
        shot("01-editor")

        // Captions: Karaoke style.
        if !element("tool.Style").exists { element("caption.1").tap() }
        tap("tool.Style")
        tap("chip.Karaoke")
        shot("02-captions")
        tap("panel.done")
        deselect("caption.1")

        // Filters on the first clip.
        selectClip(0)
        tap("tool.Filters")
        tap("filter.teal_orange")
        shot("03-filters")
        tap("panel.done")

        // Speed.
        if !element("tool.Speed").exists { selectClip(0) }
        tap("tool.Speed")
        shot("04-speed")
        tap("panel.done")
        deselect("clip.0")

        // Export.
        tap("editor.export")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        shot("05-export")
    }
}

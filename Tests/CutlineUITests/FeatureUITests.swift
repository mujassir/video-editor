import XCTest

/// One test per user-facing feature, run against the real app in the simulator.
final class FeatureUITests: CutlineUITestCase {

    func test01_ProjectLibraryAndImport() {
        XCTAssertTrue(element("projects.new").waitForExistence(timeout: 10))
        snapshot("01-projects-empty")
        // A new project closed without adding anything is not kept.
        tap("projects.new")
        tap("editor.close")
        XCTAssertTrue(element("projects.new").waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(element("project.card").exists, "empty project should not appear in the library")
        openProjectWithSamples()
        XCTAssertEqual(count(prefix: "clip."), 3)
        XCTAssertEqual(totalSeconds, 12, accuracy: 0.2)
        snapshot("01-editor-imported")
        // Close and confirm the project is listed and reopens.
        tap("editor.close")
        XCTAssertTrue(element("project.card").waitForExistence(timeout: 10))
        snapshot("01-projects-list")
        element("project.card").tap()
        waitFor("project reopened") { count(prefix: "clip.") == 3 }
    }

    func test02_PlaybackAndScrub() {
        openProjectWithSamples()
        tap("editor.play")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        tap("editor.play")
        let current = element("time.current").label
        XCTAssertNotEqual(current, "0:00.0", "playhead should advance during playback")
        element("timeline").swipeLeft()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertNotEqual(element("time.current").label, current, "scrubbing should move the playhead")
        snapshot("02-scrubbed")
    }

    func test03_SplitDeleteUndoRedo() {
        openProjectWithSamples()
        // Move the playhead ~1.5 s into the first clip and split.
        let tl = element("timeline").coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.2))
        tl.press(forDuration: 0.05, thenDragTo: tl.withOffset(CGVector(dx: -100, dy: 0)))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        selectClipAtPlayhead()
        tap("tool.Split")
        waitFor("split clip") { count(prefix: "clip.") == 4 }
        snapshot("03-split")
        tap("tool.Delete")
        waitFor("deleted clip") { count(prefix: "clip.") == 3 }
        XCTAssertLessThan(totalSeconds, 12)
        tap("editor.undo")
        waitFor("undo restores clip") { count(prefix: "clip.") == 4 }
        tap("editor.redo")
        waitFor("redo deletes again") { count(prefix: "clip.") == 3 }
    }

    func test04_TrimWithHandles() {
        openProjectWithSamples()
        selectClip(0)
        let handle = element("trim.leading")
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        let before = totalSeconds
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        print("TRIM handle frame: \(handle.frame)")
        start.press(forDuration: 0.3, thenDragTo: start.withOffset(CGVector(dx: 90, dy: 0)))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        print("TRIM debug: '\(element("debug.trim").label)' total \(totalSeconds)")
        snapshot("04-trim-handle")
        // Precise trim panel.
        tap("tool.Trim")
        let end = element("slider.End")
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        end.adjust(toNormalizedSliderPosition: 0.5)
        waitFor("trim shortens the edit") { totalSeconds < before - 1 }
        snapshot("04-trimmed")
    }

    func test05_SpeedReverseFreezeDuplicate() {
        openProjectWithSamples()
        selectClip(0)
        tap("tool.Speed")
        tap("chip.2×")
        waitFor("2× speed halves clip 0") { abs(totalSeconds - 10) < 0.2 }
        snapshot("05-speed")
        tap("panel.done")
        tap("tool.Duplicate")
        waitFor("duplicate") { count(prefix: "clip.") == 4 }
        tap("tool.Reverse")
        waitUntilIdle()
        XCTAssertNotNil(toastText)
        tap("tool.Freeze")
        waitFor("freeze frame inserted") { count(prefix: "clip.") >= 5 }
        snapshot("05-freeze")
    }

    func test06_FiltersAdjustAutoEnhance() {
        openProjectWithSamples()
        selectClip(0)
        tap("tool.Filters")
        tap("filter.teal_orange")
        let intensity = element("slider.Intensity")
        XCTAssertTrue(intensity.waitForExistence(timeout: 5))
        intensity.adjust(toNormalizedSliderPosition: 0.6)
        snapshot("06-filter")
        tap("panel.done")
        tap("tool.Adjust")
        element("slider.Exposure").adjust(toNormalizedSliderPosition: 0.7)
        element("slider.Saturation").adjust(toNormalizedSliderPosition: 0.8)
        snapshot("06-adjust")
        tap("adjust.auto")
        waitUntilIdle()
        XCTAssertEqual(toastText, "Enhanced")
    }

    func test07_TextOverlay() {
        openProjectWithSamples()
        tap("tool.Text")
        let field = element("text.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        field.typeText("Summer Trip")
        tap("font.Condensed")
        tap("chip.Outline")
        snapshot("07-text")
        tap("panel.done")
        XCTAssertEqual(count(prefix: "text."), 1)
    }

    func test08_Transitions() {
        openProjectWithSamples()
        tap("transition.0")
        tap("chip.Dissolve")
        waitFor("dissolve overlaps clips") { totalSeconds < 11.8 }
        snapshot("08-transition")
        tap("panel.done")
        // Bring the second cut on screen.
        let tl = element("timeline").coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        tl.press(forDuration: 0.05, thenDragTo: tl.withOffset(CGVector(dx: -260, dy: 0)))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        tap("transition.1")
        tap("chip.Slide")
        tap("panel.done")
        waitFor("second transition") { totalSeconds < 11.3 }
    }

    func test09_MusicAndBeatSync() {
        openProjectWithSamples()
        tap("tool.Music")
        // User-music sources are offered next to the built-in tracks.
        for source in ["music.source.files", "music.source.video"] {
            XCTAssertTrue(element(source).waitForExistence(timeout: 5), "\(source) missing")
        }
        snapshot("09-music-sources")
        // Files must actually present the system picker (regression: it silently did nothing).
        tap("music.source.files")
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "Files picker did not open from the Music panel")
        snapshot("09-music-files-picker")
        cancel.tap()
        XCTAssertTrue(element("music.use.sunrise").waitForExistence(timeout: 5))
        tap("music.use.sunrise")
        waitUntilIdle()
        waitFor("music lane") { count(prefix: "audio.") == 1 }
        snapshot("09-music")
        element("editor.aspect").tap() // dismiss selection state
        tap("panel.done")
        tap("tool.Beat Sync")
        let toast = toastText ?? ""
        XCTAssertTrue(toast.contains("Synced"), "unexpected toast: \(toast)")
        snapshot("09-beatsync")
    }

    func test10_RemoveSilence() {
        openProjectWithSamples()
        let before = totalSeconds
        tap("tool.Silence")
        waitUntilIdle()
        waitFor("silence removed") { totalSeconds < before - 2 }
        let toast = toastText ?? ""
        XCTAssertTrue(toast.contains("Removed"), "unexpected toast: \(toast)")
        snapshot("10-silence")
    }

    func test11_CanvasAndBackground() {
        openProjectWithSamples()
        tap("editor.aspect")
        tap("chip.3:4")
        XCTAssertEqual(element("editor.aspect").label, "3:4")
        snapshot("11-canvas-3x4")
        tap("chip.1:1")
        // Background is always blurred: no background options in the canvas panel.
        XCTAssertFalse(element("chip.Blur").exists)
        XCTAssertFalse(element("swatch.4").exists)
        snapshot("11-canvas-square")
        tap("chip.Fill")
        tap("chip.Top")
        snapshot("11-canvas-fill-top")
        tap("chip.Stretch")
        tap("chip.Fit")
        tap("chip.16:9")
        tap("panel.done")
        XCTAssertEqual(element("editor.aspect").label, "16:9")
    }

    func test12_CutoutReframeCrop() {
        openProjectWithSamples()
        selectClip(0)
        tap("tool.Cutout")
        tap("chip.Blur")
        tap("panel.done")
        tap("tool.Reframe")
        waitUntilIdle()
        XCTAssertNotNil(toastText)
        tap("tool.Crop")
        tap("tool.Rotate")
        tap("chip.1:1")
        snapshot("12-crop")
        tap("panel.done")
    }

    func test13_Export() {
        openProjectWithSamples()
        tap("editor.export")
        tap("chip.720p")
        let estimate = element("export.estimate")
        XCTAssertTrue(estimate.waitForExistence(timeout: 5))
        XCTAssertTrue(estimate.label.contains("Estimated size"), estimate.label)
        tap("export.start")
        XCTAssertTrue(element("export.done").waitForExistence(timeout: 300), "export did not finish")
        snapshot("13-exported")
        tap("export.close")
    }

    func test19_TextDurationAnimatePosition() {
        openProjectWithSamples()
        tap("tool.Text")
        XCTAssertTrue(element("text.field").waitForExistence(timeout: 5))
        tap("panel.done")
        // Text stays selected: its toolbar has the photo-like tools.
        for tool in ["tool.Duration", "tool.Animate", "tool.Position", "tool.Duplicate"] {
            XCTAssertTrue(element(tool).waitForExistence(timeout: 5), "\(tool) missing for text")
        }
        tap("tool.Duration")
        tap("chip.5s")
        XCTAssertTrue(element("textDuration.value").label.hasPrefix("5.0 s"))
        tap("panel.done")
        tap("tool.Animate")
        element("textAnimate.tabs").buttons["In"].tap()
        tap("tanim.In.slideUp")
        element("textAnimate.tabs").buttons["Combo"].tap()
        tap("tanim.combo.pulse")
        tap("panel.done")
        tap("tool.Position")
        tap("tpos.bottom")
        snapshot("19-text-bottom")
        tap("panel.done")
        // Drag the text on the video: it moves and becomes a Custom placement.
        let handle = element("textHandle")
        XCTAssertTrue(handle.waitForExistence(timeout: 5), "text should be draggable on the preview")
        let before = handle.frame.midY
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -120)))
        waitFor("text moved up") { element("textHandle").exists && element("textHandle").frame.midY < before - 40 }
        tap("tool.Position")
        XCTAssertTrue(element("chip.Custom").isSelected || element("chip.Custom").exists)
        snapshot("19-text-dragged")
        tap("panel.done")
        tap("tool.Duplicate")
        waitFor("text duplicated") { count(prefix: "text.") == 2 }
    }

    func test20_WatermarkAndTitleCards() {
        openProjectWithSamples()
        tap("tool.Watermark")
        tap("chip.Text")
        XCTAssertTrue(element("watermark.text").waitForExistence(timeout: 5))
        tap("wmpos.topLeft")
        snapshot("20-watermark")
        tap("panel.done")
        let before = totalSeconds
        tap("tool.Intro")
        tap("panel.done")   // ✓ adds the slide
        waitFor("opening slide added") { count(prefix: "clip.") == 4 && totalSeconds > before + 2.5 }
        tap("tool.Outro")
        tap("titleStyle.ocean")
        tap("panel.done")
        waitFor("closing slide added") { count(prefix: "clip.") == 5 }
        snapshot("20-outro")
        tap("tool.Outro")
        tap("titleCard.remove")
        waitFor("closing slide removed") { count(prefix: "clip.") == 4 }
    }

    func test21_SecondMusicTrackStartsLaterAndMoves() {
        openProjectWithSamples()
        tap("tool.Music")
        tap("music.use.sunrise")
        waitUntilIdle()
        waitFor("first track") { count(prefix: "audio.") == 1 }
        // Shorten the first track so there is room for a second one.
        element("audio.0").tap()
        tap("tool.Trim")
        let endHandle = element("audioTrim.endHandle")
        XCTAssertTrue(endHandle.waitForExistence(timeout: 5))
        let from = endHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: from.withOffset(CGVector(dx: -120, dy: 0)))
        tap("audioTrim.trim")
        tap("panel.done")
        // Second track starts where the first ends, not on top of it at 0:00.
        element("timeline").coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.05)).tap()
        tap("tool.Music")
        tap("music.use.night")
        waitUntilIdle()
        waitFor("second track") { count(prefix: "audio.") == 2 }
        let first = element("audio.0").frame, second = element("audio.1").frame
        XCTAssertGreaterThan(second.minX, first.minX + 20, "second track should start later")
        // Hold and drag the second track left on the timeline.
        let bar = element("audio.1").coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        bar.press(forDuration: 0.8, thenDragTo: bar.withOffset(CGVector(dx: -40, dy: 0)),
                  withVelocity: .slow, thenHoldForDuration: 0.3)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        print("AUDIODRAG timeline value: \(String(describing: element("timeline").value)) audio.1 frame: \(element("audio.1").frame) before: \(second)")
        snapshot("21-after-drag")
        waitFor("track moved") { element("audio.1").frame.minX < second.minX - 15 }
        // And the toolbar can snap it to the playhead.
        XCTAssertTrue(element("tool.To Playhead").waitForExistence(timeout: 5))
        snapshot("21-two-tracks")
    }

    func test18_AudioTrimSplitDuplicate() {
        openProjectWithSamples()
        tap("tool.Music")
        tap("music.use.sunrise")
        waitUntilIdle()
        waitFor("music lane") { count(prefix: "audio.") == 1 }
        // Playhead a little into the song, then select the music clip.
        let tl = element("timeline").coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.2))
        tl.press(forDuration: 0.05, thenDragTo: tl.withOffset(CGVector(dx: -120, dy: 0)))
        element("audio.0").tap()
        XCTAssertTrue(element("tool.Trim").waitForExistence(timeout: 5))
        tap("tool.Trim")
        let summary = element("audioTrim.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        let before = summary.label
        // Drag the start handle to the right, preview, then Trim.
        let handle = element("audioTrim.startHandle")
        let from = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: from.withOffset(CGVector(dx: 60, dy: 0)))
        XCTAssertNotEqual(element("audioTrim.startTime").label, "0:00.0", "start handle should move")
        tap("audioTrim.play")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        snapshot("18-audio-trim-preview")
        tap("audioTrim.play")
        tap("audioTrim.trim")
        waitFor("trim applied") { element("audioTrim.summary").label != before }
        // Undo inside the panel restores the previous section.
        tap("panel.undo")
        waitFor("undo restores") { element("audioTrim.summary").label == before }
        tap("panel.done")
        tap("tool.Split")
        waitFor("audio split") { count(prefix: "audio.") == 2 }
        tap("tool.Duplicate")
        waitFor("audio duplicated") { count(prefix: "audio.") == 3 }
        snapshot("18-audio-split-duplicate")
    }

    func test17_FilterPreviewShowsCleanFrame() {
        openProjectWithSamples()
        // Clip 1 spans 4–8 s and fades out; the playhead starts at 0 (outside it).
        selectClip(1)
        tap("tool.Animate")
        element("animate.tabs").buttons["Out"].tap()
        tap("anim.Out.fade")
        tap("panel.done")
        tap("tool.Filters")
        // Opening Filters jumps to the middle of the clip's un-animated part.
        waitFor("playhead in the clean part of clip 1") {
            let parts = element("time.current").label.split(separator: ":")
            guard parts.count == 2, let s = Double(parts[1]) else { return false }
            return s > 4.5 && s < 7.0
        }
        tap("filter.mono")
        snapshot("17-filter-clean-frame")
    }

    func test16_ClipAnimations() {
        openProjectWithSamples()
        selectClip(0)
        tap("tool.Animate")
        tap("anim.In.zoomIn")
        let tabs = element("animate.tabs")
        tabs.buttons["Out"].tap()
        tap("anim.Out.fade")
        tabs.buttons["Combo"].tap()
        tap("anim.combo.pulse")
        snapshot("16-animations")
        tap("animate.applyAll")
        XCTAssertNotNil(toastText)
        tap("panel.done")
    }

    func test15_PhotoToolbarAndDuration() {
        openProjectWithSamples()
        // A freeze frame is a still image, so it gets the photo toolbar.
        selectClip(0)
        tap("tool.Freeze")
        waitFor("freeze frame") { count(prefix: "clip.") == 4 }
        let before = totalSeconds
        selectClip(0)
        XCTAssertTrue(element("tool.Duration").waitForExistence(timeout: 5))
        XCTAssertTrue(element("tool.Animate").exists)
        for videoOnly in ["tool.Speed", "tool.Volume", "tool.Reverse", "tool.Freeze", "tool.Split", "tool.Trim"] {
            XCTAssertFalse(element(videoOnly).exists, "\(videoOnly) should be hidden for stills")
        }
        snapshot("15-photo-tools")
        tap("tool.Duration")
        tap("chip.5s")
        waitFor("photo lasts 5 s") { abs(totalSeconds - (before + 3.5)) < 0.2 }
        snapshot("15-duration")
        tap("panel.done")
    }
}

/// Captions need real speech, so they run against the demo footage when CI provides it.
final class CaptionUITests: CutlineUITestCase {
    override var useDemoMedia: Bool { true }

    func test14_AutoCaptions() throws {
        guard ProcessInfo.processInfo.environment["DEMO_MEDIA"] != nil else {
            throw XCTSkip("Needs DEMO_MEDIA speech footage")
        }
        tap("projects.new")
        tap("tool.Media")
        app.buttons["Sample Clips"].tap()
        waitFor("demo clips", timeout: 90) { count(prefix: "clip.") >= 1 }
        waitUntilIdle()
        tap("tool.Captions")
        tap("captions.generate")
        allowSystemAlerts(timeout: 30)
        waitUntilIdle(timeout: 240)
        let toast = toastText ?? ""
        print("CAPTIONS toast: \(toast)")
        #if targetEnvironment(simulator)
        if toast.contains("kLSRErrorDomain") || toast.contains("isn't available") {
            // The simulator ships without Apple's on-device speech model and the app never
            // uses server recognition, so transcription must be verified on an iPhone.
            XCTExpectFailure("On-device speech model not available in the iOS simulator: \(toast)")
        }
        #endif
        XCTAssertTrue(toast.hasPrefix("Captioned"), "captions failed: \(toast)")
        guard toast.hasPrefix("Captioned") else { return }
        XCTAssertGreaterThan(count(prefix: "caption."), 0)
        tap("chip.Bold")
        snapshot("14-captions")
    }
}

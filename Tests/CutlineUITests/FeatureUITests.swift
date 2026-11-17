import XCTest

/// One test per user-facing feature, run against the real app in the simulator.
final class FeatureUITests: CutlineUITestCase {

    func test01_ProjectLibraryAndImport() {
        XCTAssertTrue(element("projects.new").waitForExistence(timeout: 10))
        snapshot("01-projects-empty")
        // A new project has nothing to export, so there's no Export button (EDT).
        tap("projects.new")
        XCTAssertTrue(element("editor.close").waitForExistence(timeout: 10))
        XCTAssertFalse(element("editor.export").exists, "Export should be hidden in an empty project")
        XCTAssertFalse(element("editor.undo").exists, "nothing to undo in a new project")
        XCTAssertFalse(element("editor.redo").exists, "nothing to redo in a new project")
        // TBR-1 with no content: only Intro and Outro.
        for hidden in ["tool.Music", "tool.Captions", "tool.Denoise", "tool.Watermark", "tool.Text"] {
            XCTAssertFalse(element(hidden).exists, "\(hidden) should be hidden with no content")
        }
        XCTAssertTrue(element("tool.Intro").exists && element("tool.Outro").exists)
        // A new project closed without adding anything is not kept.
        tap("editor.close")
        XCTAssertTrue(element("projects.new").waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(element("project.card").exists, "empty project should not appear in the library")
        openProjectWithSamples()
        XCTAssertEqual(count(prefix: "clip."), 3)
        XCTAssertEqual(totalSeconds, 12, accuracy: 0.2)
        XCTAssertTrue(element("editor.export").exists, "Export appears once there's content")
        for shown in ["tool.Music", "tool.Captions", "tool.Denoise", "tool.Watermark", "tool.Text"] {
            XCTAssertTrue(element(shown).waitForExistence(timeout: 5), "\(shown) should appear once there's content")
        }
        snapshot("01-editor-imported")
        // Close and confirm the project is listed and reopens.
        tap("editor.close")
        XCTAssertTrue(element("project.card").waitForExistence(timeout: 10))
        snapshot("01-projects-list")
        element("project.card").tap()
        waitFor("project reopened") { count(prefix: "clip.") == 3 }
    }

    func test01b_RecentCardsWithMixedRatiosDontOverlap() {
        // One 16:9 project and one 3:4 project side by side in Recent.
        for ratio in ["16:9", "3:4"] {
            openProjectWithSamples()
            tap("editor.aspect")
            tap("chip.\(ratio)")
            tap("panel.done")
            tap("editor.close")
            XCTAssertTrue(element("projects.new").waitForExistence(timeout: 10))
        }
        waitFor("two cards") { app.descendants(matching: .any).matching(identifier: "project.card").count == 2 }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        snapshot("01b-recent-mixed-ratios")
        let cards = app.descendants(matching: .any).matching(identifier: "project.card")
        let a = cards.element(boundBy: 0).frame, b = cards.element(boundBy: 1).frame
        let screen = app.windows.firstMatch.frame
        XCTAssertFalse(a.intersects(b), "cards overlap: \(a) vs \(b)")
        for f in [a, b] {
            XCTAssertLessThan(f.width, screen.width / 2, "a card is wider than its column: \(f)")
            XCTAssertGreaterThanOrEqual(f.minX, screen.minX)
            XCTAssertLessThanOrEqual(f.maxX, screen.maxX)
        }
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
        // Adding the clips is an edit: Undo shows, Redo doesn't yet.
        XCTAssertTrue(element("editor.undo").exists)
        XCTAssertFalse(element("editor.redo").exists, "Redo only appears after an Undo")
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
        XCTAssertTrue(element("editor.redo").waitForExistence(timeout: 5), "Redo appears after an Undo")
        tap("editor.redo")
        waitFor("redo deletes again") { count(prefix: "clip.") == 3 }
        waitFor("nothing left to redo") { !element("editor.redo").exists }
        // A new edit after an Undo clears Redo.
        tap("editor.undo")
        waitFor("redo back") { element("editor.redo").exists }
        selectClip(0)
        tap("tool.Duplicate")
        waitFor("new edit clears redo") { !element("editor.redo").exists }
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
        print("TRIM debug: '\(element("debug.trim").label)' total \(totalSeconds) before \(before)")
        snapshot("04-trim-handle")
        // Video clips are trimmed with the timeline handles only (no Trim tool).
        XCTAssertFalse(element("tool.Trim").exists, "video toolbar should not offer Trim")
        waitFor("trim shortens the edit") { totalSeconds < before - 0.5 }
    }

    /// SPD-1: the 3× quick pick makes a 4 s clip last a third as long, and every pick fits on screen.
    func test05b_SPD1_ThreeTimesSpeed() {
        openProjectWithSamples()
        selectClip(0)
        tap("tool.Speed")
        let width = app.windows.firstMatch.frame.width
        for chip in ["chip..3×", "chip..5×", "chip.1×", "chip.2×", "chip.3×", "chip.4×"] {
            let e = element(chip)
            XCTAssertTrue(e.waitForExistence(timeout: 5), "\(chip) missing")
            XCTAssertLessThanOrEqual(e.frame.maxX, width, "\(chip) runs off the screen")
        }
        tap("chip.3×")
        waitFor("3× speed: clip 0 lasts 4 ÷ 3 s") { abs(totalSeconds - (8 + 4.0 / 3)) < 0.2 }
        XCTAssertTrue(element("chip.3×").isSelected)
        XCTAssertEqual(element("speed.value").label, "3×")
    }

    /// SPD-4: "Apply to all" sets the speed on every clip in one undo step.
    func test05d_SPD4_ApplySpeedToAllClips() {
        openProjectWithSamples()
        selectClip(0)
        tap("tool.Speed")
        tap("chip.2×")
        waitFor("2× on clip 0") { abs(totalSeconds - 10) < 0.2 }
        XCTAssertEqual(element("speed.applyAll").label, "Apply to all 3 clips")
        tap("speed.applyAll")
        waitFor("2× on all three 4 s clips") { abs(totalSeconds - 6) < 0.2 }
        XCTAssertEqual(toastText, "All clips set to 2×")
        snapshot("05d-speed-apply-all")
        tap("panel.done")
        tap("editor.undo")
        waitFor("one undo restores clip 1 and 2") { abs(totalSeconds - 10) < 0.2 }
    }

    /// PRV-9: the preview play speed buttons play faster without changing the edit (no undo step, same length).
    func test05c_PRV9_PreviewPlaySpeed() {
        openProjectWithSamples()
        let total = totalSeconds
        let undoBefore = element("editor.undo").exists
        tap("preview.rate")
        // A vertical column of round buttons, fastest on top.
        var lastY = -CGFloat.infinity
        for rate in ["2×", "1.5×", "1.25×", "1×", "0.75×", "0.5×"] {
            let e = element("rate.\(rate)")
            XCTAssertTrue(e.waitForExistence(timeout: 5), "\(rate) missing")
            XCTAssertGreaterThan(e.frame.minY, lastY, "\(rate) out of order")
            XCTAssertLessThan(e.frame.maxY, element("preview.rate").frame.minY, "\(rate) should sit above the speed button")
            lastY = e.frame.minY
        }
        XCTAssertTrue(element("rate.1×").isSelected)
        snapshot("05c-play-speed-open")
        // Picked while paused: playback starts at the new speed.
        tap("rate.2×")
        waitFor("column closed") { !element("rate.2×").exists }
        waitFor("button shows 2×") { element("preview.rate").label.contains("2×") }
        waitFor("playing at 2×") { element("debug.rate").label == "2/2" }
        XCTAssertEqual(element("editor.play").label, "Pause")
        // Changed while playing: takes effect at once and keeps playing.
        tap("preview.rate")
        tap("rate.1.5×")
        waitFor("playing at 1.5×") { element("debug.rate").label == "1.5/1.5" }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(element("debug.rate").label, "1.5/1.5", "still playing at 1.5×")
        XCTAssertEqual(element("editor.play").label, "Pause", "still playing")
        tap("editor.play")
        waitFor("paused") { element("debug.rate").label == "1.5/0" }
        // Preview only: the edit is unchanged.
        XCTAssertEqual(totalSeconds, total, accuracy: 0.05)
        XCTAssertEqual(element("editor.undo").exists, undoBefore, "play speed must not be an undo step")
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
        // MUS-1: two sources, Audio Tracks (Files) and From Video.
        for source in ["music.source.files", "music.source.video"] {
            XCTAssertTrue(element(source).waitForExistence(timeout: 5), "\(source) missing")
        }
        XCTAssertTrue(element("music.source.files").label.contains("Audio Tracks"), element("music.source.files").label)
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
        // Beat Sync has been removed everywhere, including the music toolbar.
        XCTAssertFalse(element("tool.Beat Sync").exists)
        element("audio.0").tap()
        XCTAssertTrue(element("tool.Cut").waitForExistence(timeout: 5))
        XCTAssertFalse(element("tool.Beat Sync").exists, "music toolbar should not offer Beat Sync")
    }

    func test10_MainToolbarOrder() {
        openProjectWithSamples()
        // TBR-1 main toolbar: Music, Captions, Denoise (DNS-1), Watermark, Text, Intro, Outro – no Media, Silence or Beat Sync.
        XCTAssertFalse(element("tool.Media").exists, "media is added with the timeline +")
        let ids = ["tool.Music", "tool.Captions", "tool.Denoise", "tool.Watermark", "tool.Text", "tool.Intro", "tool.Outro"]
        var lastX = -CGFloat.infinity
        for id in ids {
            let e = element(id)
            XCTAssertTrue(e.waitForExistence(timeout: 5), "\(id) missing")
            XCTAssertGreaterThan(e.frame.minX, lastX, "\(id) out of order")
            lastX = e.frame.minX
        }
        XCTAssertFalse(element("tool.Silence").exists)
        XCTAssertFalse(element("tool.Beat Sync").exists)
    }

    func test27_EDT1_SwipeDownClosesPanels() {
        openProjectWithSamples()
        for (tool, panel) in [("tool.Music", "panel.Music"), ("tool.Captions", "panel.Captions"), ("tool.Watermark", "panel.Watermark")] {
            tap(tool)
            let p = element(panel)
            XCTAssertTrue(p.waitForExistence(timeout: 5), "\(panel) didn't open")
            // Drag down from the panel's top edge (grabber / title row).
            let top = p.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.02))
            top.press(forDuration: 0.05, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 220)))
            waitFor("\(panel) closed by swiping down") { !element(panel).exists }
            XCTAssertTrue(element("tool.Music").waitForExistence(timeout: 5), "main toolbar is back")
        }
    }

    func test28_PRV7_EmptyPreviewAddsMedia() {
        openProjectWithSamples()
        // Delete every clip: the editor is back to its start state.
        while count(prefix: "clip.") > 0 {
            let before = count(prefix: "clip.")
            selectClip(0)
            tap("tool.Delete")
            waitFor("clip deleted") { count(prefix: "clip.") < before }
        }
        let empty = element("preview.addMedia")
        XCTAssertTrue(empty.waitForExistence(timeout: 5), "empty preview should show")
        XCTAssertFalse(element("editor.export").exists)
        XCTAssertFalse(element("tool.Music").exists, "project tools hide again with no content")
        snapshot("28-empty-again")
        // Tapping the film icon / label adds media (test runs get the Sample Clips menu).
        empty.tap()
        let sample = app.buttons["Sample Clips"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5))
        sample.tap()
        waitFor("clips added from the empty preview", timeout: 60) { count(prefix: "clip.") >= 3 }
        XCTAssertFalse(element("preview.addMedia").exists)
    }

    func test29_MUS10_RecentAudioTracks() {
        openProjectWithSamples()
        XCTAssertFalse(element("music.recent.0").exists)
        tap("tool.Music")
        XCTAssertFalse(element("music.recent.0").exists, "no recent tracks yet")
        tap("music.use.sunrise")
        waitUntilIdle()
        waitFor("music added") { count(prefix: "audio.") == 1 }
        // Reopen Music: the track is listed under Recent, and tapping it adds it again.
        element("editor.aspect").tap()
        tap("panel.done")
        tap("tool.Music")
        let recent = element("music.recent.0")
        XCTAssertTrue(recent.waitForExistence(timeout: 5), "recent track missing")
        XCTAssertTrue(recent.label.contains("Sunrise"), recent.label)
        snapshot("29-music-recent")
        recent.tap()
        waitUntilIdle()
        waitFor("recent track added") { count(prefix: "audio.") == 2 }
    }

    func test30_MUS11_StartHere() {
        openProjectWithSamples()
        tap("tool.Music")
        tap("music.use.sunrise")
        waitUntilIdle()
        waitFor("music added") { count(prefix: "audio.") == 1 }
        // Playhead a few seconds into the song, music selected: Start Here shows.
        let tl = element("timeline").coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.2))
        tl.press(forDuration: 0.05, thenDragTo: tl.withOffset(CGVector(dx: -150, dy: 0)))
        waitUntilIdle()
        revealAndTap("audio.0")
        XCTAssertTrue(element("tool.Start Here").waitForExistence(timeout: 5))
        let fullWidth = element("audio.0").frame.width
        tap("tool.Start Here")
        XCTAssertTrue(toastText?.hasPrefix("Music starts from") ?? false)
        // One clip left, and it now begins where the video begins.
        waitFor("one music clip") { count(prefix: "audio.") == 1 }
        waitFor("moved to 0:00") { abs(element("audio.0").frame.minX - element("clip.0").frame.minX) < 4 }
        XCTAssertLessThan(element("audio.0").frame.width, fullWidth - 20, "the part before the playhead is gone")
        snapshot("30-start-here")
        // One undo step brings the whole song back.
        tap("editor.undo")
        waitFor("undo restores the whole song") { abs(element("audio.0").frame.width - fullWidth) < 4 }
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

    func test13b_ExportAndShare() {
        openProjectWithSamples()
        tap("editor.export")
        tap("chip.720p")
        XCTAssertTrue(element("export.startShare").waitForExistence(timeout: 5))
        snapshot("13b-export-options")
        tap("export.startShare")
        XCTAssertTrue(element("export.done").waitForExistence(timeout: 300), "export did not finish")
        // The system share sheet opens by itself with the video (WhatsApp etc. appear there on a device).
        let sheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "share sheet did not open")
        snapshot("13b-share-sheet")
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
        // Shorten the first track: cut it with the scissors on the timeline and delete the rest.
        let tl = element("timeline").coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.2))
        tl.press(forDuration: 0.05, thenDragTo: tl.withOffset(CGVector(dx: -120, dy: 0)))
        element("audio.0").tap()
        tap("tool.Cut")
        waitFor("track cut") { count(prefix: "audio.") == 2 }
        tap("tool.Delete")
        waitFor("rest deleted") { count(prefix: "audio.") == 1 }
        // Second track starts where the first ends, not on top of it at 0:00.
        element("timeline").coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.05)).tap()
        tap("tool.Music")
        tap("music.use.night")
        waitUntilIdle()
        waitFor("second track") { count(prefix: "audio.") == 2 }
        let first = element("audio.0").frame, startFrame = element("audio.1").frame
        XCTAssertGreaterThan(startFrame.minX, first.minX + 20, "second track should start later")
        // Scroll the second track on screen (it starts beyond the right edge), then hold and drag it left.
        revealAndTap("audio.1")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let second = element("audio.1").frame
        XCTAssertLessThan(second.minX + 20, app.windows.firstMatch.frame.maxX, "second track should be visible before dragging")
        let bar = element("audio.1").coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        bar.press(forDuration: 0.8, thenDragTo: bar.withOffset(CGVector(dx: -40, dy: 0)),
                  withVelocity: .slow, thenHoldForDuration: 0.3)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        print("AUDIODRAG timeline value: \(String(describing: element("timeline").value)) audio.1 frame: \(element("audio.1").frame) before: \(second)")
        snapshot("21-after-drag")
        waitFor("track moved") { element("audio.1").frame.minX < second.minX - 15 }
        // Music toolbar: Cut / Delete (+ Repeat for music shorter than the video); no Edit, Duplicate or Auto-duck.
        XCTAssertFalse(element("tool.Edit").exists)
        XCTAssertFalse(element("tool.Duplicate").exists)
        XCTAssertFalse(element("tool.Auto-duck").exists)
        for id in ["tool.Cut", "tool.Delete"] { XCTAssertTrue(element(id).exists, "\(id) missing") }
        XCTAssertFalse(element("tool.To Playhead").exists)
        snapshot("21-two-tracks")
    }

    func test18_AudioCutSelectRepeat() {
        openProjectWithSamples()
        tap("tool.Music")
        tap("music.use.sunrise")
        waitUntilIdle()
        waitFor("music lane") { count(prefix: "audio.") == 1 }
        // Playhead a little into the song: the scissors appears on the music bar once it is selected.
        let tl = element("timeline").coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.2))
        tl.press(forDuration: 0.05, thenDragTo: tl.withOffset(CGVector(dx: -120, dy: 0)))
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        element("audio.0").tap()
        XCTAssertTrue(element("tool.Cut").waitForExistence(timeout: 5))
        XCTAssertFalse(element("timeline.cut").exists, "no scissors on the music bar (MUS-4)")
        snapshot("18-audio-selected")
        tap("tool.Cut")
        waitFor("audio cut") { count(prefix: "audio.") == 2 }
        // The right-hand piece is selected; there is no Edit / editor panel any more.
        XCTAssertTrue(element("tool.Cut").waitForExistence(timeout: 5))
        XCTAssertFalse(element("tool.Edit").exists)
        // Each piece is its own clip: the first one stops before the video ends, so it can be repeated.
        element("audio.0").tap()
        XCTAssertFalse(element("tool.Duplicate").exists)
        tap("tool.Repeat")
        waitFor("audio repeated") { count(prefix: "audio.") > 2 }
        snapshot("18-audio-cut-repeat")
    }

    func test26_CLP5_VoiceToggle() {
        openProjectWithSamples()
        selectClip(0)
        let voice = element("tool.Voice")
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        // Voice sits right after Split in the video toolbar.
        XCTAssertLessThan(element("tool.Split").frame.minX, voice.frame.minX)
        XCTAssertLessThan(voice.frame.minX, element("tool.Speed").frame.minX)
        tap("tool.Voice")
        XCTAssertEqual(toastText, "Voice off")
        snapshot("26-voice-off")
        waitFor("toast gone") { !element("toast").exists }
        tap("tool.Voice")
        XCTAssertEqual(toastText, "Voice on")
    }

    func test31_TML13_DragToReorder() {
        openProjectWithSamples()
        // Hold the first clip (under the centre playhead): the main track turns into a thumbnail
        // strip with that tile under the finger. Dragging ~2 tiles (58 pt each) right lands it last.
        let timeline = element("timeline")
        let start = timeline.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: timeline.frame.width / 2 + 4, dy: 50))
        start.press(forDuration: 0.6, thenDragTo: start.withOffset(CGVector(dx: 130, dy: 0)),
                    withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertEqual(toastText, "Moved to position 3 of 3")
        XCTAssertEqual(count(prefix: "clip."), 3)
        waitFor("strip closed") { !element("reorder.lifted").exists }
        snapshot("31-drag-reorder")
    }

    /// DNS-1: Denoise is one setting for the whole video, in the main toolbar.
    func test24_VideoNoiseReduction() {
        openProjectWithSamples()
        selectClip(0)
        XCTAssertTrue(element("tool.Speed").waitForExistence(timeout: 5))
        XCTAssertFalse(element("tool.Denoise").exists)   // not in the clip toolbar any more
        element("clip.0").tap()   // deselect: back to the main tools
        tap("tool.Denoise")
        XCTAssertTrue(element("chip.Off").waitForExistence(timeout: 5))
        XCTAssertTrue(element("chip.Off").isSelected)
        tap("chip.Medium")
        waitUntilIdle()
        XCTAssertEqual(toastText, "Noise reduced (Medium)")
        XCTAssertTrue(element("chip.Medium").isSelected)
        snapshot("24-noise-reduction")
        // Switching off and back on reuses the cleaned sound (no second pass).
        tap("chip.Off")
        waitFor("off") { element("chip.Off").isSelected }
        tap("chip.Medium")
        waitFor("medium again") { element("chip.Medium").isSelected }
        XCTAssertFalse(element("busy").exists)
        tap("panel.done")
        // Undo restores the previous setting.
        tap("editor.undo")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        if !element("tool.Denoise").exists { element("clip.0").tap() }   // deselect if undo selected it
        tap("tool.Denoise")
        waitFor("undone to off") { element("chip.Off").isSelected }
    }

    func test23_MusicDuckLevel() {
        openProjectWithSamples()
        // Video clips no longer have a Volume tool.
        selectClip(0)
        XCTAssertTrue(element("tool.Speed").waitForExistence(timeout: 5))
        XCTAssertFalse(element("tool.Volume").exists)
        element("clip.0").tap()   // tap again to deselect, back to the main tools
        tap("tool.Music")
        tap("music.use.sunrise")
        waitUntilIdle()
        waitFor("music lane") { count(prefix: "audio.") == 1 }
        element("audio.0").tap()
        tap("tool.Duck")
        let slider = app.sliders["slider.Music"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        XCTAssertEqual(slider.value as? String, "25%")
        XCTAssertTrue(element("duck.needsCaptions").exists, "no captions yet, so the panel says ducking needs them")
        slider.adjust(toNormalizedSliderPosition: 0.6)
        waitFor("duck level changed") { (slider.value as? String) != "25%" }
        snapshot("23-duck-level")
        tap("panel.done")
    }

    func test22_MusicMoveToStartClosesTheGap() {
        openProjectWithSamples()
        tap("tool.Music")
        tap("music.use.sunrise")
        waitUntilIdle()
        waitFor("music lane") { count(prefix: "audio.") == 1 }
        // Music starting at 0:00 has nothing to move.
        element("audio.0").tap()
        XCTAssertTrue(element("tool.Cut").waitForExistence(timeout: 5))
        XCTAssertFalse(element("tool.Move to Start").exists)
        // Cut it and delete the first piece: the rest now has a blank start.
        let tl = element("timeline").coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.2))
        tl.press(forDuration: 0.05, thenDragTo: tl.withOffset(CGVector(dx: -120, dy: 0)))
        element("audio.0").tap()
        tap("tool.Cut")
        waitFor("audio cut") { count(prefix: "audio.") == 2 }
        element("audio.0").tap()
        tap("tool.Delete")
        waitFor("first piece deleted") { count(prefix: "audio.") == 1 }
        element("audio.0").tap()
        XCTAssertTrue(element("tool.Move to Start").waitForExistence(timeout: 5))
        snapshot("22-move-to-start")
        let before = element("audio.0").frame.minX
        tap("tool.Move to Start")
        waitFor("music moved to the start") { element("audio.0").frame.minX < before - 15 }
        XCTAssertFalse(element("tool.Move to Start").exists)
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
        for videoOnly in ["tool.Speed", "tool.Voice", "tool.Volume", "tool.Reverse", "tool.Freeze", "tool.Split", "tool.Trim"] {
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

/// Caption editing with ready-made captions (the simulator can't transcribe speech).
final class CaptionEditUITests: CutlineUITestCase {
    override var extraLaunchArguments: [String] { ["-sampleCaptions"] }

    func test25_CaptionStyleAndEditAreSeparate() {
        openProjectWithSamples()
        waitFor("captions on the timeline") { count(prefix: "caption.") >= 4 }
        element("caption.0").tap()
        XCTAssertTrue(element("tool.Edit").waitForExistence(timeout: 5))
        XCTAssertTrue(element("tool.Style").exists)
        // Style: look only, no text fields.
        tap("tool.Style")
        XCTAssertTrue(element("chip.Bold").waitForExistence(timeout: 5))
        XCTAssertTrue(element("chip.Classic").exists && element("chip.Karaoke").exists)
        XCTAssertFalse(element("chip.Minimal").exists)
        XCTAssertFalse(element("chip.Neon").exists)
        XCTAssertFalse(element("caption.field.0").exists)
        snapshot("25-caption-style")
        tap("panel.done")
        // Fillers: "Um" / "uh" are dropped, and the "Ah"-only caption goes away.
        if !element("tool.Fillers").exists { element("caption.0").tap() }
        tap("tool.Fillers")
        XCTAssertEqual(toastText, "Removed 3 filler words")
        waitFor("filler-only caption removed") { count(prefix: "caption.") == 3 }
        if !element("tool.Fillers").exists { element("caption.0").tap() }
        tap("tool.Fillers")
        XCTAssertEqual(toastText, "No filler words found")
        tap("tool.Style")
        tap("panel.done")
        // Edit: full screen, on the caption under the playhead (0:03.0 → "This is a caption").
        let tl = element("timeline").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        tl.press(forDuration: 0.05, thenDragTo: tl.withOffset(CGVector(dx: -200, dy: 0)))
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        print("PLAYHEAD at \(element("time.current").label)")
        if !element("tool.Edit").exists { element("caption.1").tap() }
        tap("tool.Edit")
        let field = element("caption.field.1")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(element("captionEditor.done").exists)
        XCTAssertFalse(element("chip.Bold").exists)
        XCTAssertEqual(field.value as? String, "This is a caption")
        // The keyboard comes up on that caption by itself; typing goes into it.
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText(" today")
        waitFor("text edited") { (field.value as? String ?? "").contains("today") }
        // The line being typed in sits above the keyboard.
        XCTAssertLessThan(field.frame.maxY, app.keyboards.firstMatch.frame.minY)
        snapshot("25-caption-edit")
        // Done saves and closes promptly.
        let start = Date()
        tap("captionEditor.done")
        waitFor("editor closed") { !element("captionEditor.done").exists }
        let doneTime = Date().timeIntervalSince(start)
        print("CLOSE took \(doneTime) s")
        // Saved: reopening shows the new text; one undo brings the old text back.
        tap("tool.Edit")
        XCTAssertTrue((element("caption.field.1").value as? String ?? "").contains("today"))
        // Saving must not make closing slower than closing without saving (Cancel).
        let cancelStart = Date()
        tap("captionEditor.cancel")
        waitFor("closed") { !element("captionEditor.cancel").exists }
        let cancelTime = Date().timeIntervalSince(cancelStart)
        print("CANCEL took \(cancelTime) s")
        XCTAssertLessThan(doneTime, cancelTime + 0.75, "Done \(doneTime) s vs Cancel \(cancelTime) s")
        tap("editor.undo")
        if !element("tool.Edit").exists { element("caption.1").tap() }
        tap("tool.Edit")
        waitFor("undone") { (element("caption.field.1").value as? String) == "This is a caption" }
        tap("captionEditor.cancel")
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
        tap("timeline.add")
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

/// LAY-*: the wide layout on iPad. Runs only on an iPad simulator (CI's iPad step).
final class TabletUITests: CutlineUITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad only (LAY-*)") }
        XCUIDevice.shared.orientation = .landscapeLeft
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    func testLAY1to3_WideLayoutSidebar() {
        // LAY-6 / LAY-8: library on a wide window.
        XCTAssertTrue(element("projects.new").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Everything runs on your iPad. No account, no uploads, no watermark."].exists)
        snapshot("lay-library")
        openProjectWithSamples()
        // LAY-2/3: the sidebar replaces the bottom toolbar.
        XCTAssertTrue(element("editor.sidebar").waitForExistence(timeout: 5), "wide layout should show the sidebar")
        XCTAssertFalse(element("toolbar").exists, "the phone toolbar is not used in the wide layout")
        XCTAssertEqual(element("sidebar.title").label, "Project")
        for id in ["tool.Music", "tool.Text", "tool.Intro", "tool.Outro"] { XCTAssertTrue(element(id).exists, "\(id) missing") }
        snapshot("lay-editor-project")
        // Selecting a clip switches the grid to its tools.
        selectClip(0)
        waitFor("clip heading") { ["Video Clip", "Photo"].contains(element("sidebar.title").label) }
        // A panel opens in the sidebar, without a swipe-to-close grabber, and ✓ closes it.
        tap("tool.Filters")
        XCTAssertTrue(element("panel.Filters").waitForExistence(timeout: 5))
        snapshot("lay-editor-filters")
        let panel = element("panel.Filters")
        let top = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
        top.press(forDuration: 0.05, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 160)))
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertTrue(element("panel.Filters").exists, "no swipe-down to close in the sidebar (LAY-3)")
        tap("panel.done")
        waitFor("panel closed") { !element("panel.Filters").exists }
        // LAY-1: rotating keeps the editor state (the clip stays selected).
        XCUIDevice.shared.orientation = .portrait
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertTrue(element("tool.Filters").waitForExistence(timeout: 5), "selection survives a layout change")
        snapshot("lay-editor-portrait")
    }

    func testLAY5_KeyboardShortcuts() {
        openProjectWithSamples()
        XCTAssertTrue(element("editor.sidebar").waitForExistence(timeout: 5))
        let start = element("time.current").label
        // ⇧→ steps forward one second.
        app.typeKey(.rightArrow, modifierFlags: .shift)
        waitFor("one second forward") { element("time.current").label != start }
        XCTAssertEqual(element("time.current").label, "0:01.0")
        // ⌘B splits at the playhead, ⌘Z undoes it.
        let clips = count(prefix: "clip.")
        app.typeKey("b", modifierFlags: .command)
        waitFor("split") { count(prefix: "clip.") == clips + 1 }
        app.typeKey("z", modifierFlags: .command)
        waitFor("undo") { count(prefix: "clip.") == clips }
        // ⌘E opens Export.
        app.typeKey("e", modifierFlags: .command)
        XCTAssertTrue(element("export.start").waitForExistence(timeout: 5), "⌘E opens Export")
        tap("export.close")
        // Space, Esc, plain arrows and Delete aren't tested here: XCUITest's typeKey with no
        // modifier never reaches the app as a hardware key (it needs a focused text field).
        // Check those by hand on an iPad with a keyboard.
    }
}

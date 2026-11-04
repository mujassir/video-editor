import XCTest

/// Scripted product tour used to record the demo video.
///
/// CI records the simulator screen while this runs, and narration clips are
/// laid over the recording at the times this test logs ("CHAPTER <n> <epoch>").
/// Each chapter waits for its narration length (read from DEMO_SCRIPT) so the
/// picture and voice stay in sync.
final class DemoTourUITests: CutlineUITestCase {
    override var useDemoMedia: Bool { true }
    private var durations: [Double] = []

    private func chapter(_ index: Int, _ actions: () -> Void) {
        let start = Date()
        print("CHAPTER \(index) \(String(format: "%.3f", start.timeIntervalSince1970))")
        actions()
        let target = (index < durations.count ? durations[index] : 6) + 0.7
        let remaining = target - Date().timeIntervalSince(start)
        if remaining > 0 { pause(remaining) }
    }

    private func pause(_ seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func play(_ seconds: Double) {
        tap("editor.play")
        pause(seconds)
        tap("editor.play")
    }

    func testDemoTour() throws {
        guard let script = ProcessInfo.processInfo.environment["DEMO_SCRIPT"],
              let data = FileManager.default.contents(atPath: script),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["durations"] as? [Double] else {
            throw XCTSkip("DEMO_SCRIPT not provided")
        }
        durations = list
        executionTimeAllowance = 3600
        XCTAssertTrue(element("projects.new").waitForExistence(timeout: 15))

        // 0 – Intro (title card is added in post; show the library).
        chapter(0) { pause(1) }

        // 1 – New project + import.
        chapter(1) {
            tap("projects.new")
            pause(0.8)
            tap("tool.Media")
            pause(0.6)
            app.buttons["Sample Clips"].tap()
            waitFor("demo clips", timeout: 120) { count(prefix: "clip.") >= 4 }
            waitUntilIdle()
            tap("editor.aspect")
            tap("chip.16:9")
            pause(0.5)
            tap("panel.done")
        }

        // 2 – Playback, scrub, zoom.
        chapter(2) {
            play(3)
            element("timeline").swipeLeft(velocity: .slow)
            pause(1)
            element("timeline").pinch(withScale: 1.8, velocity: 1)
            pause(0.8)
            element("timeline").swipeRight(velocity: .slow)
        }

        // 3 – Split, trim, duplicate, undo.
        chapter(3) {
            let tl = element("timeline").coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.2))
            tl.press(forDuration: 0.05, thenDragTo: tl.withOffset(CGVector(dx: -110, dy: 0)))
            pause(0.6)
            selectClipAtPlayhead()
            tap("tool.Split")
            pause(1)
            let handle = element("trim.trailing")
            if handle.waitForExistence(timeout: 3) {
                let c = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                c.press(forDuration: 0.2, thenDragTo: c.withOffset(CGVector(dx: -40, dy: 0)))
            }
            pause(0.8)
            tap("tool.Duplicate")
            pause(1)
            tap("editor.undo")
            pause(0.8)
        }

        // 4 – Speed, reverse, freeze.
        chapter(4) {
            tap("tool.Speed")
            pause(0.6)
            tap("chip.2×")
            pause(1.2)
            tap("chip.0.5×")
            pause(1.2)
            tap("chip.1×")
            tap("panel.done")
            tap("tool.Reverse")
            waitUntilIdle()
            pause(0.8)
            tap("tool.Reverse")
            pause(0.5)
        }

        // 5 – Filters & adjustments.
        chapter(5) {
            tap("tool.Filters")
            pause(1.2)
            for f in ["filter.vivid", "filter.teal_orange", "filter.mono", "filter.golden"] {
                tap(f)
                pause(1.1)
            }
            tap("panel.done")
            tap("tool.Adjust")
            pause(0.6)
            element("slider.Contrast").adjust(toNormalizedSliderPosition: 0.65)
            pause(0.6)
            element("slider.Vignette").adjust(toNormalizedSliderPosition: 0.5)
            pause(0.8)
        }

        // 6 – Auto enhance.
        chapter(6) {
            tap("adjust.auto")
            waitUntilIdle()
            pause(1.5)
            tap("panel.done")
        }

        // 7 – Text overlay.
        chapter(7) {
            app.tap() // clear focus
            tap("editor.aspect")
            tap("panel.done")
            selectNone()
            tap("tool.Text")
            let field = element("text.field")
            if field.waitForExistence(timeout: 5) {
                field.tap()
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 9))
                field.typeText("ROAD TRIP\n")
            }
            pause(0.6)
            tap("font.Condensed")
            pause(0.5)
            tap("chip.Outline")
            pause(0.5)
            tap("chip.Pop")
            pause(2)
            tap("panel.done")
        }

        // 8 – Transitions.
        chapter(8) {
            selectNone()
            tap("transition.0")
            pause(0.5)
            tap("chip.Dissolve")
            pause(2.2)
            tap("chip.Zoom")
            pause(2.2)
            tap("panel.done")
            let tl = element("timeline").coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            tl.press(forDuration: 0.05, thenDragTo: tl.withOffset(CGVector(dx: -200, dy: 0)))
            pause(0.6)
            tap("transition.1")
            tap("chip.Glitch")
            pause(2.2)
            tap("panel.done")
        }

        // 9 – Music + beat sync.
        chapter(9) {
            selectNone()
            tap("tool.Music")
            pause(1)
            tap("music.use.sunrise")
            waitUntilIdle()
            pause(0.8)
            tap("tool.Beat Sync")
            pause(1.5)
            seekStart()
            play(3)
        }

        // 10 – Remove silence.
        chapter(10) {
            selectNone()
            tap("tool.Silence")
            waitUntilIdle()
            pause(1.5)
        }


        // 11 – Canvas formats.
        chapter(11) {
            selectNone()
            tap("editor.aspect")
            for r in ["chip.1:1", "chip.4:5", "chip.16:9", "chip.9:16"] {
                tap(r)
                pause(1.1)
            }
            tap("panel.done")
        }

        // 12 – Auto reframe on the vlog close-up (9:16 canvas).
        chapter(12) {
            seekToVlog()
            selectClipAtPlayhead()
            tap("tool.Reframe")
            waitUntilIdle()
            pause(0.5)
            play(3)
        }

        // 13 – Export.
        chapter(13) {
            tap("editor.export")
            pause(0.8)
            tap("chip.720p")
            pause(0.5)
            tap("export.start")
            XCTAssertTrue(element("export.done").waitForExistence(timeout: 600))
            pause(2.5)
        }

        // 14 – Outro.
        chapter(14) {
            tap("export.close")
            pause(1)
            tap("editor.close")
            pause(1.5)
        }
    }

    // MARK: Navigation helpers

    private func selectNone() {
        // Tapping empty timeline space clears the selection.
        // The ruler (top 18 pt of the timeline) never holds a clip.
        let timeline = element("timeline")
        timeline.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: timeline.frame.width * 0.8, dy: 8)).tap()
        pause(0.3)
    }

    private func seekStart() {
        element("timeline").swipeRight(velocity: .fast)
        pause(0.8)
    }

    /// The vlog clip is the second demo file.
    private func seekToVlog() {
        seekStart()
        let clip = element("clip.1")
        if clip.exists {
            // Drag the timeline so clip 1's start sits under the playhead.
            let timeline = element("timeline")
            let dx = clip.frame.minX + 6 - timeline.frame.midX
            let from = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: -dx, dy: 0)))
            pause(1)
        }
    }

}

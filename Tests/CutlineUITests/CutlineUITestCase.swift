import XCTest
import UIKit

/// Shared helpers: launch with a clean library and sample media, query timeline items, capture screenshots.
class CutlineUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-sampleMedia"]
        if let folder = ProcessInfo.processInfo.environment["DEMO_MEDIA"], !folder.isEmpty, useDemoMedia {
            app.launchArguments += ["-demoMedia", folder]
        }
        app.launch()
    }

    /// Subclasses that need real footage (speech for captions) override this.
    var useDemoMedia: Bool { false }

    func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func tap(_ id: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let e = element(id)
        XCTAssertTrue(e.waitForExistence(timeout: timeout), "\(id) not found", file: file, line: line)
        if id.hasPrefix("tool.") {
            // Off-screen tool: scroll the toolbar towards it (frame-based – isHittable throws off screen).
            let bar = element("toolbar")
            let screen = app.windows.firstMatch.frame
            var attempts = 0
            while attempts < 5, e.frame.maxX > screen.maxX - 4 || e.frame.minX < screen.minX + 4 {
                let from = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                let dx: CGFloat = e.frame.maxX > screen.maxX ? -min(250, e.frame.maxX - screen.maxX + 40) : 250
                from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: dx, dy: 0)))
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                attempts += 1
            }
        }
        e.tap()
    }

    func count(prefix: String) -> Int {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).count
    }

    func waitFor(_ description: String, timeout: TimeInterval = 20, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("Timed out waiting for \(description)")
    }

    func waitUntilIdle(timeout: TimeInterval = 120) {
        let busy = element("busy")
        let deadline = Date().addingTimeInterval(timeout)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        while busy.exists && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        XCTAssertFalse(busy.exists, "Background analysis did not finish")
    }

    var totalSeconds: Double {
        // "/ 1:02.5"
        let label = element("time.total").label.replacingOccurrences(of: "/", with: "").trimmingCharacters(in: .whitespaces)
        let parts = label.split(separator: ":")
        guard parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]) else { return -1 }
        return m * 60 + s
    }

    var toastText: String? {
        let t = element("toast")
        guard t.waitForExistence(timeout: 8) else { return nil }
        let label = t.label
        print("TOAST: \(label)")
        return label
    }

    /// New project with the three sample clips on the timeline.
    func openProjectWithSamples(expectedClips: Int = 3) {
        tap("projects.new")
        tap("tool.Media")
        let sample = app.buttons["Sample Clips"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5))
        sample.tap()
        waitFor("sample clips on the timeline", timeout: 60) { count(prefix: "clip.") >= expectedClips }
        waitUntilIdle()
    }

    /// Taps the main track right under the playhead.
    func selectClipAtPlayhead() {
        let timeline = element("timeline")
        let point = timeline.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: timeline.frame.width / 2 + 4, dy: 50))
        point.tap()
        XCTAssertTrue(element("tool.Split").waitForExistence(timeout: 5), "clip tools should appear")
    }

    func selectClip(_ index: Int) {
        let clip = element("clip.\(index)")
        XCTAssertTrue(clip.waitForExistence(timeout: 5))
        clip.tap()
        XCTAssertTrue(element("tool.Split").waitForExistence(timeout: 5), "clip tools should appear")
    }

    /// Saves a screenshot as an attachment and prints a small JPEG for CI log review.
    func snapshot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if ProcessInfo.processInfo.environment["PRINT_SCREENSHOTS"] == "1" {
            let image = shot.image
            let target = CGSize(width: 300, height: 300 * image.size.height / image.size.width)
            let small = UIGraphicsImageRenderer(size: target).image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
            if let data = small.jpegData(compressionQuality: 0.55) {
                print("SCREENSHOT \(name) \(data.base64EncodedString())")
            }
        }
    }
}

import XCTest

/// Captures every main screen in demo mode for UI review.
/// CI passes TEST_RUNNER_SCREENSHOT_DIR; PNGs are also attached to the .xcresult.
final class ScreenshotTests: XCTestCase {
    private let screens: [(name: String, args: [String])] = [
        ("01-camera", ["-category", "camera"]),
        ("02-favorite", ["-category", "favorite"]),
        ("03-pip", ["-category", "pip"]),
        ("04-video", ["-category", "movie"]),
        ("05-picture", ["-category", "picture"]),
        ("06-transition", ["-category", "transition"]),
        ("07-overlay", ["-category", "overlay"]),
        ("08-title", ["-category", "title"]),
        ("09-logo", ["-category", "logo"]),
        ("10-audio", ["-category", "audio"]),
        ("11-adjust-color-ptz", ["-category", "adjust"]),
        ("12-auto-switch", ["-category", "auto"]),
        ("13-replay", ["-category", "replay"]),
        ("14-outputs", ["-screen", "outputs"]),
        ("15-add-source", ["-screen", "addsource"]),
        ("16-shows", ["-screen", "shows"])
    ]

    override func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    func testCaptureScreens() throws {
        let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"].map { URL(fileURLWithPath: $0) }
        if let dir { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        for s in screens {
            let app = XCUIApplication()
            app.launchArguments = ["-demo", "-uitest"] + s.args
            app.launch()
            XCUIDevice.shared.orientation = .landscapeLeft
            // The studio UI is up once the CUT button exists; fail loudly (with the UI tree) if it never appears.
            let up = app.buttons["CUT"].waitForExistence(timeout: 45)
            XCTAssertTrue(up, "\(s.name): studio UI did not appear. state=\(app.state.rawValue)\n\(app.debugDescription.prefix(3000))")
            sleep(4) // sheets open 1.5 s after launch; demo frames refresh every 0.5 s
            let shot = XCUIScreen.main.screenshot()
            let a = XCTAttachment(screenshot: shot)
            a.name = s.name
            a.lifetime = .keepAlways
            add(a)
            if let dir { try shot.pngRepresentation.write(to: dir.appendingPathComponent(s.name + ".png")) }
            app.terminate()
        }
    }
}

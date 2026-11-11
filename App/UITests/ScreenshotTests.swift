import XCTest

/// Captures every main screen in demo mode for UI review.
/// CI passes TEST_RUNNER_SCREENSHOT_DIR; PNGs are also attached to the .xcresult.
final class ScreenshotTests: XCTestCase {
    private let screens: [(name: String, args: [String])] = [
        ("01-studio-titles", ["-panel", "titles"]),
        ("02-studio-audio-mixer", ["-panel", "audio"]),
        ("03-studio-source-color-key-ptz", ["-panel", "source"]),
        ("04-studio-scopes", ["-panel", "scopes"]),
        ("05-studio-auto-switch", ["-panel", "auto"]),
        ("06-studio-replay", ["-panel", "replay"]),
        ("07-studio-fullwidth", ["-screen", "nopanel"]),
        ("08-outputs", ["-screen", "outputs"]),
        ("09-add-source", ["-screen", "addsource"]),
        ("10-shows", ["-screen", "shows"])
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
            app.launchArguments = ["-demo"] + s.args
            app.launch()
            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(6) // demo sources animate, sheets open after 1.5 s
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

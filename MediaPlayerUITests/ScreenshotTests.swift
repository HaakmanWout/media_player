import XCTest

/// Captures screens for visual checks; run with -only-testing to grab a specific one.
final class ScreenshotTests: XCTestCase {
    private func capture(_ app: XCUIApplication, _ name: String) {
        sleep(2)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func select(_ tab: String, in app: XCUIApplication) {
        let button = app.tabBars.buttons[tab]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        for _ in 0..<3 where !button.isSelected {
            button.tap()
            sleep(1)
        }
        XCTAssertTrue(button.isSelected, "Couldn't switch to the \(tab) tab")
    }

    func testPodcastsTab() {
        let app = XCUIApplication()
        app.launch()
        select("Podcasts", in: app)
        capture(app, "Podcasts")
    }

    func testMusicTabAndPlaylist() {
        let app = XCUIApplication()
        app.launch()
        select("Music", in: app)
        capture(app, "Music")
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Road Trip'")).firstMatch.tap()
        capture(app, "Playlist")
    }

    /// Rapid screenshots right after opening the folder picker, to see what it shows first.
    func testFolderPickerOpening() {
        let app = XCUIApplication()
        app.launch()
        select("Music", in: app)
        app.buttons["Library Folder"].firstMatch.tap()
        for index in 0..<10 {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Picker-\(index)"
            shot.lifetime = .keepAlways
            add(shot)
            usleep(250_000)
        }
    }

    /// Rapid screenshots while switching tabs and opening/closing a playlist, to spot flicker.
    func testPageSwitchFrames() {
        let app = XCUIApplication()
        app.launch()
        select("Music", in: app)
        sleep(2)
        func burst(_ label: String, _ action: () -> Void) {
            action()
            for index in 0..<8 {
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.name = "\(label)-\(index)"
                shot.lifetime = .keepAlways
                add(shot)
                usleep(80_000)
            }
            sleep(1)
        }
        burst("toPodcasts") { app.tabBars.buttons["Podcasts"].tap() }
        burst("toMusic") { app.tabBars.buttons["Music"].tap() }
        burst("openPlaylist") { app.buttons.matching(NSPredicate(format: "label CONTAINS 'Road Trip'")).firstMatch.tap() }
        burst("back") { app.navigationBars.buttons.element(boundBy: 0).tap() }
    }

    /// Page switching with the mini player visible (something playing); pair with a screen recording.
    func testPageSwitchWhilePlaying() {
        let app = XCUIApplication()
        app.launch()
        select("Music", in: app)
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Road Trip'")).firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Midnight Echo'")).firstMatch.tap()
        sleep(2)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(2)
        for _ in 0..<2 {
            app.tabBars.buttons["Podcasts"].tap(); sleep(2)
            app.tabBars.buttons["Music"].tap(); sleep(2)
            app.buttons.matching(NSPredicate(format: "label CONTAINS 'Road Trip'")).firstMatch.tap(); sleep(2)
            app.navigationBars.buttons.element(boundBy: 0).tap(); sleep(2)
        }
    }
}

import XCTest

final class FolderButtonTests: XCTestCase {
    func testFolderButtonOpensPickerDirectly() {
        let app = XCUIApplication()
        app.launch()

        for tab in ["Music", "Podcasts"] {
            app.tabBars.buttons[tab].tap()
            app.buttons["Library Folder"].firstMatch.tap()

            // The iOS 26 folder picker has an "Open" button and is dismissed by swiping down (no Cancel).
            let open = app.buttons["Open"]
            XCTAssertTrue(open.waitForExistence(timeout: 5), "\(tab): the folder picker should open right away")
            XCTAssertFalse(app.buttons["Choose Folder…"].exists, "\(tab): there should be no intermediate menu")

            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "\(tab)-picker"
            shot.lifetime = .keepAlways
            add(shot)

            let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            top.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
            XCTAssertTrue(app.buttons["Library Folder"].firstMatch.waitForExistence(timeout: 5))
            XCTAssertFalse(open.exists, "\(tab): the picker should be dismissed")
        }
    }
}

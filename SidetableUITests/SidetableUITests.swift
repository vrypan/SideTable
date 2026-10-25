import XCTest

final class SidetableUITests: XCTestCase {
    @MainActor func testAboutDisplaysBuildVersion() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--preview"]
        app.launch()
        app.menuBars.menuBarItems["SideTable"].click()
        app.menuItems["About SideTable"].click()
        let version = app.staticTexts.matching(NSPredicate(format: "value MATCHES %@", ".*Version [0-9]+[.][0-9]+[.][0-9]+.*")).firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "About SideTable build version"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
    }

    @MainActor func testOpenLinkReviewsDestination() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--preview"]
        app.launch()
        app.typeKey("l", modifierFlags: .command)
        let field = app.textFields["apronLink"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("https://link.apron.chat/#server=wss://chat.example/&room=general&message=100")
        app.buttons["Continue"].click()
        XCTAssertTrue(app.staticTexts["Connect to this new server?"].waitForExistence(timeout: 3))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Open standardized Apron link"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Cancel"].click()
        app.terminate()
    }

    @MainActor func testPreviewNavigationAndComposer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["General"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.textViews["messageComposer"].firstMatch.exists)
        app.buttons["toggleMembers"].click()
        XCTAssertTrue(app.staticTexts["Members"].firstMatch.waitForExistence(timeout: 3))
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(app.textFields["Jump to a conversation…"].waitForExistence(timeout: 3))
        app.buttons["Close"].click()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Sidetable native preview"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
    }
    @MainActor func testMarkdownAndUploadPreview() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--preview-development"]
        app.launch()
        XCTAssertTrue(app.buttons["Copy code block"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Copy code block"].firstMatch.click()
        app.staticTexts["Design"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["wireframes.pdf"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Cancel upload of wireframes.pdf"].exists)
        XCTAssertTrue(app.buttons["Reattach to Composer"].firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Attachment delivery controls"; screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
    }
    @MainActor func testUserProfileFromConversation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--preview"]
        app.launch()
        // The sidebar account button is first; exercise the author avatar in the conversation.
        let author = app.buttons.matching(identifier: "View profile for Ada Lovelace").element(boundBy: 1)
        XCTAssertTrue(author.waitForExistence(timeout: 10))
        author.click()
        XCTAssertTrue(app.buttons["Copy User ID"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["moderator"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["profileBio"].waitForExistence(timeout: 3))
        app.buttons["Done"].click()
        app.terminate()
    }
}

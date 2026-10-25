import XCTest
import AppKit

final class SidetableUITests: XCTestCase {
    @MainActor func testClipboardAttachmentsWithExistingText() throws {
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--preview-composer"]
        app.launch()
        defer { app.terminate() }
        let editor = app.textViews["messageComposer"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeText("Here is a screenshot")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        board.clearContents()
        board.setData(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), forType: .png)
        editor.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Screenshot.png"].waitForExistence(timeout: 3))
        XCTAssertEqual(editor.value as? String, "Here is a screenshot")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("paste-test-\(UUID().uuidString).txt")
        try Data("attachment".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        board.clearContents()
        board.writeObjects([file as NSURL])
        board.setString(file.path, forType: .string)
        editor.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts[file.lastPathComponent].waitForExistence(timeout: 3))
        XCTAssertEqual(editor.value as? String, "Here is a screenshot")
    }

    @MainActor func testNativeURLsOpenReviewWithoutConnecting() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--preview"]
        app.launch()
        defer { app.terminate() }
        for link in ["sidetable://open?server=wss://new.example/&room=general", "apron:?server=wss://new.example/&room=general"] {
            app.open(try XCTUnwrap(URL(string: link)))
            let field = app.textFields["apronLink"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            XCTAssertEqual(app.windows.count, 1, "Opening a URL should reuse the existing window")
            XCTAssertEqual(app.textFields.matching(identifier: "apronLink").count, 1)
            XCTAssertEqual(field.value as? String, link)
            XCTAssertFalse(app.buttons["Continue"].exists)
            XCTAssertTrue(app.buttons["Open"].exists)
            XCTAssertTrue(app.staticTexts["Connect to this new server?"].waitForExistence(timeout: 3))
            app.buttons["Cancel"].click()
        }
        app.typeKey("w", modifierFlags: .command)
        app.open(try XCTUnwrap(URL(string: "sidetable://open?server=wss://closed-window.example/")))
        XCTAssertTrue(app.textFields["apronLink"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()
    }

    @MainActor func testRestoresViewedMessageInsteadOfLatest() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--preview-restored"]
        app.launch()
        defer { app.terminate() }
        if !app.windows.firstMatch.waitForExistence(timeout: 2) { app.typeKey("n", modifierFlags: .command) }
        let target = app.staticTexts.matching(identifier: "Earlier conversation message 31.").firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        let transcript = app.scrollViews.element(boundBy: 1)
        XCTAssertTrue(transcript.frame.contains(CGPoint(x: target.frame.midX, y: target.frame.midY)))
        let latest = app.staticTexts.matching(identifier: "Latest message — visible on opening.").firstMatch
        XCTAssertFalse(latest.exists && transcript.frame.contains(CGPoint(x: latest.frame.midX, y: latest.frame.midY)))
        app.buttons["Latest"].click()
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        let visible = NSPredicate { _, _ in
            latest.exists && transcript.frame.contains(CGPoint(x: latest.frame.midX, y: latest.frame.midY))
        }
        expectation(for: visible, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["Latest"])
        waitForExpectations(timeout: 5)
    }

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
        app.activate()
        // macOS may restore the no-window state left by the URL lifecycle test.
        if !app.windows.firstMatch.waitForExistence(timeout: 2) {
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
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

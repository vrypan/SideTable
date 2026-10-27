import XCTest
import AppKit

final class SidetableUITests: XCTestCase {
    @MainActor func testMessageTextContextMenuRespectsSelection() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--preview-composer"]
        app.launch()
        defer { app.terminate() }
        let text = "Morning, everyone! The first native build is ready to explore."
        let message = app.textViews[text]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        message.rightClick()
        XCTAssertTrue(app.menuItems["Reply"].waitForExistence(timeout: 3))
        let highlighted = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        highlighted.name = "Message context highlight"; highlighted.lifetime = .keepAlways
        add(highlighted)
        XCTAssertTrue(app.menuItems["Copy Text"].exists)
        XCTAssertFalse(app.menuItems["Message Actions"].exists)
        app.typeKey(.escape, modifierFlags: [])
        message.doubleClick()
        message.rightClick()
        XCTAssertTrue(message.menuItems["Copy"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.menuItems["Message Actions"].exists)
        message.menuItems["Copy"].click()
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertFalse(copied.isEmpty)
        XCTAssertTrue(copied.count < text.count)
        message.rightClick()
        app.menuItems["Message Actions"].hover()
        XCTAssertTrue(app.menuItems["Reply"].waitForExistence(timeout: 3))
        app.menuItems["Reply"].click()
        XCTAssertTrue(app.staticTexts["Replying to " + text].waitForExistence(timeout: 3))
        let transcript = app.scrollViews["transcript-general"]
        transcript.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 12, dy: message.frame.midY - transcript.frame.minY)).rightClick()
        XCTAssertTrue(app.menuItems["Reply"].waitForExistence(timeout: 3))
        let rowMenu = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        rowMenu.name = "Message row context highlight"; rowMenu.lifetime = .keepAlways
        add(rowMenu)
        app.typeKey(.escape, modifierFlags: [])
        app.buttons["sidebarRoom-development"].click()
        let heading = app.descendants(matching: .any).matching(identifier: "A readable conversation").firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        heading.rightClick()
        XCTAssertTrue(app.menuItems["Edit…"].waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.menuItems["Edit…"])
        waitForExpectations(timeout: 3)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Native selectable Markdown"; screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor func testMembersPanelFollowsActiveDiscussionAndResetsSearch() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--preview-panels", "--preview-members"]
        app.launch()
        defer { app.terminate() }
        let membersButton = app.buttons["Members of Development"]
        XCTAssertTrue(membersButton.waitForExistence(timeout: 10))
        membersButton.click()
        let title = app.staticTexts["membersDiscussion"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "Development")
        XCTAssertTrue(app.buttons["memberRow-ben"].exists)
        XCTAssertFalse(app.buttons["memberRow-maya"].exists)
        XCTAssertEqual(app.sheets.count, 0)
        let search = app.textFields["memberSearch"]
        search.click(); search.typeText("ben")
        app.buttons["sidebarRoom-general"].click()
        XCTAssertEqual(title.value as? String, "General")
        XCTAssertTrue(app.buttons["memberRow-maya"].exists)
        XCTAssertFalse(app.buttons["memberRow-ben"].exists)
        XCTAssertEqual(search.value as? String, "")
        XCTAssertEqual(app.buttons.matching(identifier: "Close panel").count, 2)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Members beside active discussion"; screenshot.lifetime = .keepAlways
        add(screenshot)
        // Closing the focused discussion transfers the member list to its neighbor.
        app.buttons.matching(identifier: "Close panel").firstMatch.click()
        XCTAssertEqual(title.value as? String, "Development")
        XCTAssertTrue(app.buttons["memberRow-ben"].exists)
        app.buttons["Close members"].click()
        XCTAssertFalse(title.exists)
        XCTAssertEqual(app.buttons.matching(identifier: "Close panel").count, 1)
        app.buttons["Members of Development"].click()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
    }

    @MainActor func testComposerLinkPreviewsCanBeRemovedAndRestoredWithoutChangingText() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--preview-composer"]
        app.launch()
        defer { app.terminate() }
        if !app.windows.firstMatch.waitForExistence(timeout: 2) { app.typeKey("n", modifierFlags: .command) }
        let editor = app.textViews["messageComposer"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let address = "https://example.com/article"
        editor.click(); editor.typeText(address)
        let remove = app.buttons["removeLinkPreview-" + address]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()
        XCTAssertFalse(remove.exists)
        XCTAssertEqual(editor.value as? String, address)
        XCTAssertTrue(app.buttons["restoreLinkPreviews"].exists)
        app.buttons["sidebarRoom-development"].click()
        XCTAssertFalse(app.buttons["restoreLinkPreviews"].exists)
        app.buttons["sidebarRoom-general"].click()
        XCTAssertTrue(app.buttons["restoreLinkPreviews"].waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, address)
        app.buttons["restoreLinkPreviews"].click()
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Composer link preview"; screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor func testComposerDisplaysPreviewImagesAndRemovesThemWithTheCard() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--preview-links", "--preview-composer"]
        app.launch()
        defer { app.terminate() }
        if !app.windows.firstMatch.waitForExistence(timeout: 2) { app.typeKey("n", modifierFlags: .command) }
        let address = "https://example.com/article"
        let image = app.images["composerLinkImage-" + address]
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        XCTAssertTrue(image.isHittable)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Composer preview images"; screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["removeLinkPreview-" + address].click()
        XCTAssertFalse(image.exists)
        XCTAssertTrue((app.textViews["messageComposer"].firstMatch.value as? String)?.contains(address) == true)
        app.buttons["restoreLinkPreviews"].click()
        XCTAssertTrue(image.waitForExistence(timeout: 5))
    }

    @MainActor func testReachingLatestClearsPanelUnreadBadgeAndDivider() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--preview-restored", "--preview-unread-clear"]
        app.launch()
        defer { app.terminate() }
        let badge = app.buttons["sidebarRoom-general"]
        XCTAssertTrue(badge.waitForExistence(timeout: 10))
        XCTAssertEqual(badge.value as? String, "49 unread")
        let latest = app.buttons["Latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        latest.click()
        expectation(for: NSPredicate(format: "value == %@", "0 unread"), evaluatedWith: badge)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "newMessagesDivider").firstMatch.exists)
    }

    @MainActor func testOpeningAtLatestKeepsNewDividerUntilUserReturns() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--preview-latest", "--preview-unread-recent"]
        app.launch()
        defer { app.terminate() }
        let room = app.buttons["sidebarRoom-general"]
        XCTAssertTrue(room.waitForExistence(timeout: 10))
        // Opening at the latest message marks it read but keeps the divider visible.
        expectation(for: NSPredicate(format: "value == %@", "0 unread"), evaluatedWith: room)
        waitForExpectations(timeout: 5)
        let divider = app.descendants(matching: .any).matching(identifier: "newMessagesDivider").firstMatch
        XCTAssertTrue(divider.waitForExistence(timeout: 2))
        sleep(1)
        XCTAssertTrue(divider.exists)
        // Leaving the latest messages and returning dismisses it.
        let transcript = app.scrollViews["transcript-general"]
        transcript.scroll(byDeltaX: 0, deltaY: 800)
        let latest = app.buttons["Latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        latest.click()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: divider)
        waitForExpectations(timeout: 5)
    }

    @MainActor func testPanelResizesIndependentlyAndResetsOnDoubleClick() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--preview-panels"]
        app.launch()
        defer { app.terminate() }
        let general = app.scrollViews["transcript-general"]
        let development = app.scrollViews["transcript-development"]
        XCTAssertTrue(general.waitForExistence(timeout: 10) && development.waitForExistence(timeout: 5))
        let handle = app.descendants(matching: .any)["panelResizeHandle-General"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        let startWidth = general.frame.width, startX = development.frame.minX
        let grip = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grip.click(forDuration: 0.3, thenDragTo: grip.withOffset(CGVector(dx: 120, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.3)
        // Only the first panel grows; the second keeps its width and moves right.
        XCTAssertEqual(general.frame.width, startWidth + 120, accuracy: 4)
        XCTAssertEqual(development.frame.minX, startX + 120, accuracy: 4)
        handle.doubleClick()
        XCTAssertEqual(general.frame.width, startWidth, accuracy: 4)
    }

    @MainActor func testRestoredShortConversationHasNoLatestButton() {
        let app = XCUIApplication()
        // Restoring a saved position that needs no scrolling must still count as the end.
        app.launchArguments = ["--preview", "--preview-restored-short"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.scrollViews["transcript-general"].waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["Latest"])
        waitForExpectations(timeout: 3)
    }

    @MainActor func testPanelHeaderMenuReordersPanels() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--preview-panels"]
        app.launch()
        defer { app.terminate() }
        let general = app.scrollViews["transcript-general"]
        let development = app.scrollViews["transcript-development"]
        XCTAssertTrue(general.waitForExistence(timeout: 10) && development.waitForExistence(timeout: 5))
        XCTAssertLessThan(general.frame.minX, development.frame.minX)
        // Header drags are not delivered by synthetic events; the menu exercises the same move.
        app.buttons.matching(identifier: "roomDetails").element(boundBy: 0).rightClick()
        app.menuItems["Move Panel Right"].click()
        expectation(for: NSPredicate { _, _ in development.frame.minX < general.frame.minX }, evaluatedWith: app)
        waitForExpectations(timeout: 3)
        app.buttons.matching(identifier: "roomDetails").element(boundBy: 1).rightClick()
        app.menuItems["Move Panel Left"].click()
        expectation(for: NSPredicate { _, _ in general.frame.minX < development.frame.minX }, evaluatedWith: app)
        waitForExpectations(timeout: 3)
    }

    @MainActor func testConversationPanelsNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--preview"]
        app.launch()
        defer { app.terminate() }
        let development = app.buttons["sidebarRoom-development"]
        XCTAssertTrue(development.waitForExistence(timeout: 10))
        XCUIElement.perform(withKeyModifiers: .command) { development.click() }
        XCTAssertEqual(app.buttons.matching(identifier: "Close panel").count, 2)
        XCTAssertEqual(app.textViews.matching(identifier: "messageComposer").count, 2)
        let headers = app.buttons.matching(identifier: "roomDetails")
        XCTAssertEqual(headers.count, 2)
        // Includes the preview banner and the title's inset within the compact room header.
        XCTAssertLessThan(headers.firstMatch.frame.minY - app.windows.firstMatch.frame.minY, 60)
        let headerScreenshot = XCTAttachment(screenshot: app.screenshot())
        headerScreenshot.name = "Compact panel headers at window top"
        headerScreenshot.lifetime = .keepAlways
        add(headerScreenshot)
        XCTAssertEqual(headers.element(boundBy: 0).frame.minY, headers.element(boundBy: 1).frame.minY, accuracy: 1)
        XCTAssertEqual(headers.element(boundBy: 0).frame.height, headers.element(boundBy: 1).frame.height, accuracy: 1)
        app.buttons["Find in Development"].click()
        XCTAssertTrue(app.textFields["Find in loaded messages"].exists)
        XCTAssertEqual(app.textFields.matching(identifier: "Find in loaded messages").count, 1)
        headers.firstMatch.click()
        XCTAssertTrue(app.staticTexts["A place for the whole team."].waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        app.buttons["Find in Development"].click()
        let design = app.buttons["sidebarRoom-design"]
        design.click()
        XCTAssertEqual(app.buttons.matching(identifier: "Close panel").count, 2)
        XCUIElement.perform(withKeyModifiers: .command) { app.buttons["sidebarRoom-general"].click() }
        XCTAssertEqual(app.buttons.matching(identifier: "Close panel").count, 2)
        app.buttons.matching(identifier: "Close panel").firstMatch.click()
        XCTAssertEqual(app.buttons.matching(identifier: "Close panel").count, 1)
    }

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
        app.launchArguments = ["--preview", "--preview-restored", "--preview-hover-layout"]
        app.launch()
        defer { app.terminate() }
        if !app.windows.firstMatch.waitForExistence(timeout: 2) { app.typeKey("n", modifierFlags: .command) }
        let target = app.textViews.matching(identifier: "Earlier conversation message 31.").firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        let transcript = app.scrollViews["transcript-general"]
        XCTAssertTrue(transcript.frame.contains(CGPoint(x: target.frame.midX, y: target.frame.midY)))
        let latest = app.textViews.matching(identifier: "Latest message — visible on opening.").firstMatch
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
        // Hover stays unobstructed; message actions are available by right-clicking.
        let lastY = latest.frame.minY
        let hoverTarget = app.textViews.matching(identifier: "Earlier conversation message 78.").firstMatch
        XCTAssertTrue(hoverTarget.exists)
        hoverTarget.hover()
        XCTAssertFalse(app.buttons["Edit message"].firstMatch.exists)
        let bounds = transcript.frame
        let staysAtEnd = NSPredicate { _, _ in
            let frame = latest.frame
            return abs(frame.minY - lastY) > 2 || !bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
        let noJump = expectation(for: staysAtEnd, evaluatedWith: app)
        noJump.isInverted = true
        waitForExpectations(timeout: 2)
        app.textViews["messageComposer"].firstMatch.hover()
        XCTAssertEqual(latest.frame.minY, lastY, accuracy: 2)
        hoverTarget.rightClick()
        XCTAssertTrue(app.menuItems["Edit…"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.menuItems["Reply"].exists)
        app.typeKey(.escape, modifierFlags: [])
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

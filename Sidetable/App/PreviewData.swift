import ApronCore
import AppKit

@MainActor enum PreviewData {
    static func populate(_ model: AppModel) {
        let server = ServerModel(ServerProfile(address: "wss://studio.example/"))
        server.snapshot.phase = .ready
        server.snapshot.server = ["title": .string(server.profile.title), "capabilities": .array(["rooms", "history", "edit", "reactions", "activity", "status", "embed:upload", "ext:bio"].map(JSONValue.string))]
        server.snapshot.you = ["user_id": .string("ada"), "name": .string("Ada Lovelace")]
        server.snapshot.store.ownID = "ada"
        for (id, name) in [("ada", "Ada Lovelace"), ("ben", "Ben Carter"), ("maya", "Maya Chen")] {
            server.snapshot.store.mergeUser(["user_id": .string(id), "name": .string(name), "status": .string("online")], complete: true)
        }
        server.snapshot.store.mergeUser(["user_id": .string("ada"), "ext": .object(["bio": .string("Building thoughtful tools.\nhttps://example.com")])])
        if let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            let foreground = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1)
            let background = NSColor(deviceRed: 0.32, green: 0.28, blue: 0.8, alpha: 1)
            for x in 0..<48 {
                for y in 0..<48 {
                    let head = (x - 24) * (x - 24) + (y - 16) * (y - 16) < 70
                    let shoulders = (x - 24) * (x - 24) + (y - 44) * (y - 44) < 300
                    bitmap.setColor(head || shoulders ? foreground : background, atX: x, y: y)
                }
            }
            if let data = bitmap.representation(using: .png, properties: [:]) {
                server.snapshot.store.mergeUser(["user_id": .string("ada"), "avatar": .string("data:image/png;base64," + data.base64EncodedString()), "roles": .array([.string("moderator")])])
            }
        }
        for (id, title, description) in [("general", "General", "A place for the whole team."), ("development", "Development", "Building something thoughtful."), ("design", "Design", "Details make the difference.")] {
            server.snapshot.store.installRoom(["room_id": .string(id), "title": .string(title), "description": .string(description)])
            server.snapshot.store.joined.insert(id); server.snapshot.store.members[id] = ["ada", "ben", "maya"]
        }
        server.snapshot.store.installRoom(["room_id": .string("release"), "title": .string("The first release"), "parent_room_id": .string("general")])
        if ProcessInfo.processInfo.arguments.contains("--preview-threads") {
            let now = UInt64(Date().timeIntervalSince1970 * 1000)
            for index in 0..<8 {
                server.snapshot.store.installRoom([
                    "room_id": .string("preview-thread-\(index)"), "parent_room_id": .string("general"),
                    "title": .string("Discussion \(index + 1)"),
                    "description": .string("A **summary** for discussion \(index + 1)."),
                    "log_id": .string(String(now - UInt64(index + 1) * 86_400_000)),
                    "latest_log_id": .string(String(now - UInt64(index) * 3_600_000))
                ])
            }
        }
        let samples = [("maya", "Morning, everyone! The first native build is ready to explore."), ("ben", "Love how quiet this feels. Rooms on the left, conversation in the middle — exactly what we need."), ("ada", "A small place for good conversations.\n\nToday’s focus: reliable reconnects, keyboard navigation, and the little details."), ("maya", "I’ve started a thread for the release checklist. Let’s keep feedback there. ✨")]
        for (index, item) in samples.enumerated() {
            let id = String(1_792_348_000_000 + index * 90_000)
            server.snapshot.store.installMessage(["message_id": .string(id), "log_id": .string(id), "room_id": .string("general"), "from": .object(["user_id": .string(item.0)]), "body": .object(["text": .string(item.1), "format": .string("markdown")])])
        }
        server.snapshot.store.installMessage(["message_id": .string("1792348500000"), "log_id": .string("1792348500000"),
            "room_id": .string("development"), "from": .object(["user_id": .string("ada")]),
            "body": .object(["format": .string("markdown"), "text": .string("""
            ## A readable conversation

            **Native Markdown**, *emphasis*, `inline code`, and [safe links](https://example.com). Καλημέρα 👋

            > A quote with context.

            1. Build the client
               - Keep the useful details
            2. Share a small example

            ```swift
            let greeting = "Hello, Apron!"
            print(greeting)
            ```

            ---

            Images stay explicit: ![sample image](https://example.com/image.png)
            <script>inert HTML</script>
            """)])])
        let previewDelivery = PendingMessage(id: "preview-upload", room: "design", account: "ada", params: [:], text: "", files: [
            StagedFile(url: URL(fileURLWithPath: "/preview/wireframes.pdf")),
            StagedFile(url: URL(fileURLWithPath: "/preview/illustration.png")),
            StagedFile(url: URL(fileURLWithPath: "/preview/notes.txt"))])
        previewDelivery.acknowledged = true
        previewDelivery.uploads[0].phase = .uploading; previewDelivery.uploads[0].bytes = 420_000; previewDelivery.uploads[0].total = 1_000_000
        previewDelivery.uploads[1].phase = .failed; previewDelivery.uploads[1].error = "Transfer interrupted. Reattach the file to try again."
        previewDelivery.uploads[2].phase = .confirming
        server.uploads.messages = [previewDelivery]
        server.selectedRoom = ProcessInfo.processInfo.arguments.contains("--preview-development") ? "development" : "general"
        if ProcessInfo.processInfo.arguments.contains("--preview-uploads") { server.selectedRoom = "design" }
        if ProcessInfo.processInfo.arguments.contains("--preview-history") {
            server.snapshot.history["general"] = RoomHistory(before: 100)
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-storage") { model.cacheUsage[server.id] = 256_000 }
        if ProcessInfo.processInfo.arguments.contains("--preview-apron-cards") {
            server.snapshot.store.installMessage([
                "message_id": .string("1792348800000"), "log_id": .string("1792348800000"), "room_id": .string("general"),
                "from": .object(["user_id": .string("ada")]),
                "body": .object(["format": .string("markdown"), "text": .string("See [the development room](apron:?room=development) and [Maya's profile](apron:?user=maya).")])
            ])
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-links") {
            model.drafts[DraftKey(server: server.id, account: server.account, room: "general")] = SavedDraft(
                text: "Two useful references:\nhttps://github.com/shazow/apron\nhttps://example.com/article")
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-latest") || ProcessInfo.processInfo.arguments.contains("--preview-arrivals") || ProcessInfo.processInfo.arguments.contains("--preview-restored") {
            for index in 0..<80 {
                let id = String(1_900_000_000_000 + index)
                server.snapshot.store.installMessage([
                    "message_id": .string(id), "log_id": .string(id), "room_id": .string("general"),
                    "from": .object(["user_id": .string("maya")]),
                    "body": .object([
                        "text": .string(index == 79 ? "Latest message — visible on opening." : "Earlier conversation message \(index + 1)." +
                            (ProcessInfo.processInfo.arguments.contains("--preview-hover-layout") && index < 77 && index % 3 == 0
                             ? "\n\n> A quoted reply with a different height.\n\n```swift\nlet message = \(index)\nprint(message)\n```\n\nMore context below the code." : "")),
                        "format": .string("markdown")])
                ])
            }
            server.snapshot.store.notices = [Notice(record: ["body": .object(["text": .string("Welcome to this conversation.")])])]
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-arrivals") {
            Task { @MainActor [weak model, weak server] in
                try? await Task.sleep(for: .milliseconds(900))
                guard let model, let server else { return }
                for index in 0..<3 {
                    let id = String(1_900_000_000_080 + index)
                    let message: JSONObject = [
                        "message_id": .string(id), "log_id": .string(id), "room_id": .string("general"),
                        "from": .object(["user_id": .string("maya")]),
                        "body": .object(["text": .string("New live message \(index + 1)")])
                    ]
                    model.incoming(message, server: server)
                    server.snapshot.store.installMessage(message)
                }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-sign-in") {
            server.snapshot = SessionSnapshot()
            server.snapshot.phase = .signIn
            server.snapshot.server = ["apron": .number(9), "title": .string("SideTable Team"), "description": .string("A **shared space** for the team."), "welcome": .string("Sign in to join the conversation."), "auth": .array(["external", "email", "token", "webauthn"].map(JSONValue.string))]
            server.snapshot.pendingSignIn = "external"
            server.selectedRoom = nil
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-thread-context") {
            server.snapshot.store.rooms["release"]?["description"] = .string("> Does it have a url? :D\n\nNot yet")
            server.snapshot.store.installMessage([
                "message_id": .string("1900000000100"), "log_id": .string("1900000000100"), "room_id": .string("release"),
                "from": .object(["user_id": .string("maya")]),
                "body": .object(["text": .string("The next reply in this thread.")])
            ])
            model.thread = "release"
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-restored") {
            model.viewedMessages[DraftKey(server: server.id, account: server.account, room: "general")] = "1900000000030"
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-unread-clear") {
            model.readMarkers[DraftKey(server: server.id, account: server.account, room: "general")] = "1900000000030"
            server.unread["general"] = 49
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-restored-short") {
            model.viewedMessages[DraftKey(server: server.id, account: server.account, room: "general")] = "1792348000000"
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-unread-recent") {
            model.readMarkers[DraftKey(server: server.id, account: server.account, room: "general")] = "1900000000077"
            server.unread["general"] = 2
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-members") {
            model.showMembers = true
            server.snapshot.store.members["general"] = ["ada", "maya"]
            server.snapshot.store.members["development"] = ["ada", "ben"]
        }
        model.servers = [server]; model.selectedServer = server.id
        if ProcessInfo.processInfo.arguments.contains("--preview-room-references") {
            server.snapshot.store.rooms["1791590929296"] = ["room_id": .string("1791590929296"), "parent_room_id": .string("general"), "title": .string("Release planning")]
            server.snapshot.store.installMessage([
                "message_id": .string("1900000000200"), "log_id": .string("1900000000200"), "room_id": .string("general"),
                "from": .object(["user_id": .string("maya")]),
                "body": .object(["format": .string("markdown"), "text": .string("Continue in #1791590929296 or ask in #development.\n\nUnknown: #missing · Literal code: `#1791590929296`")])
            ])
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-custom-emoji") || ProcessInfo.processInfo.arguments.contains("--preview-emoji-picker") {
            CustomEmojiPreview.install(on: server)
        }
    }
}

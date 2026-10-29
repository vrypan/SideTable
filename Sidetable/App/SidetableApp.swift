import SwiftUI
import AppKit
import UserNotifications
import Observation

@main
struct SidetableApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var updates = UpdateService()
    // Hosted tests must not load real accounts or touch the user's Keychain.
    @State private var model = AppModel(preview: AppRuntime.isTesting || ProcessInfo.processInfo.arguments.contains("--preview"))
    var body: some Scene {
        WindowGroup("SideTable") {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 540)
                .onAppear { delegate.model = model; updates.start() }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onOpenURL { url in
                    model.receiveLink(url)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1160, height: 780)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About SideTable") {
                    let version = Bundle.main.object(forInfoDictionaryKey: "SideTableVersion") as? String
                        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.alignment = .center
                    paragraph.paragraphSpacing = 6
                    let credits = NSMutableAttributedString(string: "github.com/vrypan/SideTable\nBuilt by vrypan, under the MIT license.", attributes: [
                        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                        .paragraphStyle: paragraph,
                        .foregroundColor: NSColor.labelColor
                    ])
                    credits.addAttribute(.link, value: URL(string: "https://github.com/vrypan/SideTable")!,
                        range: (credits.string as NSString).range(of: "github.com/vrypan/SideTable"))
                    credits.addAttribute(.link, value: URL(string: "https://vrypan.net")!,
                        range: (credits.string as NSString).range(of: "vrypan", options: .backwards))
                    credits.addAttribute(.link, value: URL(string: "https://github.com/vrypan/SideTable/blob/main/LICENSE")!,
                        range: (credits.string as NSString).range(of: "MIT license"))
                    NSApp.orderFrontStandardAboutPanel(options: [.applicationVersion: version, .credits: credits])
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
            }
            CommandGroup(after: .newItem) {
                Button("Open Link…") { model.openLinkText = ""; model.showOpenLink = true }.keyboardShortcut("l")
                Button("Add Server…") { model.showAddServer = true }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Jump to Conversation…") { model.showJump = true }.keyboardShortcut("k")
                Button("Find in Loaded Messages…") { model.showFind.toggle() }.keyboardShortcut("f")
            }
        }
        Settings { SettingsView(model: model, updates: updates) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var model: AppModel? {
        didSet {
            if model !== oldValue {
                dockBadge = model.map { DockBadgeController(model: $0) }

            }
            guard connectionMonitor == nil, let model, !model.preview else { return }
            connectionMonitor = ConnectionMonitor { [weak model] available in
                model?.setConnectionAvailable(available)
            }
        }
    }
    private var dockBadge: DockBadgeController?
    private var connectionMonitor: ConnectionMonitor?
    private var previewWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--render-preview"), ProcessInfo.processInfo.arguments.count > index + 1 {
            let path = ProcessInfo.processInfo.arguments[index + 1]
            let light = ProcessInfo.processInfo.arguments.contains("--preview-light")
            let narrow = ProcessInfo.processInfo.arguments.contains("--preview-narrow")
            let previewModel = AppModel(preview: true)
            if ProcessInfo.processInfo.arguments.contains("--preview-private-room"), let server = previewModel.current {
                server.snapshot.store.rooms["general"]?["private"] = .bool(true)
                server.snapshot.store.rooms["general"]?["title"] = nil
                server.snapshot.store.rooms["general"]?["description"] = .string("A private space to plan the next release.\n\nShare ideas, review designs, and keep track of decisions together.")
            }
            if ProcessInfo.processInfo.arguments.contains("--preview-mute-timers"), let server = previewModel.current {
                let now = Date()
                server.snapshot.mutedUntil = ["general": now.addingTimeInterval(3600), "development": now.addingTimeInterval(720), "design": .distantFuture]
                server.unread["development"] = 3
            }
            if ProcessInfo.processInfo.arguments.contains("--preview-unread-divider"), let server = previewModel.current {
                previewModel.readMarkers[DraftKey(server: server.id, account: server.account, room: "general")] = "1792348000000"
                server.unread["general"] = 2
            }
            let root: AnyView
            if ProcessInfo.processInfo.arguments.contains("--preview-server-details"), let server = previewModel.current {
                server.snapshot.server["description"] = .string("A **shared space** for thoughtful conversations.\n\nWelcome to the team.")
                root = AnyView(ServerDetailsView(model: previewModel, server: server))
            } else if ProcessInfo.processInfo.arguments.contains("--preview-emoji-picker"), let server = previewModel.current {
                root = AnyView(EmojiPicker(store: server.emojis) { _ in })
            } else if ProcessInfo.processInfo.arguments.contains("--preview-mute-timers") {
                root = AnyView(SidebarView(model: previewModel).frame(width: 260))
            } else if ProcessInfo.processInfo.arguments.contains("--preview-profile"), let server = previewModel.current {
                root = AnyView(UserProfileView(model: previewModel, server: server, recorded: server.snapshot.you))
            } else if ProcessInfo.processInfo.arguments.contains("--preview-room-details"), let server = previewModel.current {
                root = AnyView(ConversationView(model: previewModel, server: server, room: "general", isThread: false))
            } else if ProcessInfo.processInfo.arguments.contains("--preview-room-editor"), let server = previewModel.current {
                root = AnyView(EditRoomView(server: server, room: "general"))
            } else if ProcessInfo.processInfo.arguments.contains("--preview-storage") {
                root = AnyView(SettingsView(model: previewModel))
            } else { root = AnyView(ContentView(model: previewModel)) }
            let view = NSHostingView(rootView: root
                .environment(\.colorScheme, light ? .light : .dark)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, light ? .light : .dark).padding(.top, 28))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: narrow ? 760 : 1160, height: 740), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "SideTable Preview"; window.contentView = view
            window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
            window.makeKeyAndOrderFront(nil); previewWindow = window
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { print("Preview bitmap unavailable"); NSApp.terminate(nil); return }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
                    do { try data.write(to: destination); print("Rendered preview: \(destination.path)") } catch { print("Preview render failed: \(error)") }
                }
                NSApp.terminate(nil)
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.preview != true, model?.servers.contains(where: { $0.files.values.contains { !$0.isEmpty } || $0.uploads.hasUnfinishedFiles }) == true {
            let alert = NSAlert(); alert.messageText = "Quit with unfinished attachments?"
            alert.informativeText = "Draft text is saved. Staged and unfinished attachments will need to be selected again. Transfers stop when SideTable quits."
            alert.addButton(withTitle: "Keep SideTable Open"); alert.addButton(withTitle: "Quit")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        connectionMonitor?.stop()
        model?.saveDrafts()
        for server in model?.servers ?? [] { server.uploads.reset() }
        return .terminateNow
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let server = response.notification.request.content.userInfo["server"] as? String
        let room = response.notification.request.content.userInfo["room"] as? String
        await MainActor.run {
            guard let id = server.flatMap(UUID.init(uuidString:)), let room,
                  let model, let connection = model.servers.first(where: { $0.id == id }) else { return }
            model.selectedServer = id; model.selectRoom(room, server: connection)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
    }
}

/// Owned by the app delegate so badge updates continue without an open window.
@MainActor
final class DockBadgeController {
    private weak var model: AppModel?
    private let setBadge: (String?) -> Void
    private let authorizeBadge: () async -> Bool
    private var authorizationChecked = false

    init(model: AppModel, setBadge: @escaping (String?) -> Void = { NSApp.dockTile.badgeLabel = $0 },
         authorizeBadge: @escaping () async -> Bool = DockBadgeController.requestAuthorization) {
        self.model = model
        self.setBadge = setBadge
        self.authorizeBadge = authorizeBadge
        observeUnreadCount()
    }

    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            return (try? await center.requestAuthorization(options: [.badge])) == true
        }
        return settings.badgeSetting == .enabled
    }

    private func observeUnreadCount() {
        guard let model else { return }
        let count = withObservationTracking {
            model.unreadMessageCount
        } onChange: { [weak self] in
            // Observation fires before the mutation; read the new count next turn.
            Task { @MainActor [weak self] in self?.observeUnreadCount() }
        }
        setBadge(count > 0 ? String(count) : nil)
        guard count > 0, !authorizationChecked, !model.preview else { return }
        authorizationChecked = true
        Task { @MainActor [weak self, authorizeBadge] in
            guard await authorizeBadge(), let self, let model = self.model else { return }
            // Reapply after permission is granted, using the current count: the
            // user may have read messages while the system prompt was visible.
            self.setBadge(nil)
            let current = model.unreadMessageCount
            self.setBadge(current > 0 ? String(current) : nil)
        }
    }
}

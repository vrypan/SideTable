import SwiftUI
import AppKit
import UserNotifications

@main
struct SidetableApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel(preview: ProcessInfo.processInfo.arguments.contains("--preview"))
    var body: some Scene {
        WindowGroup("SideTable") {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 540)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1160, height: 780)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Server…") { model.showAddServer = true }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Jump to Conversation…") { model.showJump = true }.keyboardShortcut("k")
                Button("Find in Loaded Messages…") { model.showFind.toggle() }.keyboardShortcut("f")
            }
        }
        Settings { SettingsView(model: model) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var model: AppModel? {
        didSet {
            guard connectionMonitor == nil, let model, !model.preview else { return }
            connectionMonitor = ConnectionMonitor { [weak model] available in
                model?.setConnectionAvailable(available)
            }
        }
    }
    private var connectionMonitor: ConnectionMonitor?
    private var previewWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--render-preview"), ProcessInfo.processInfo.arguments.count > index + 1 {
            let path = ProcessInfo.processInfo.arguments[index + 1]
            let light = ProcessInfo.processInfo.arguments.contains("--preview-light")
            let narrow = ProcessInfo.processInfo.arguments.contains("--preview-narrow")
            let previewModel = AppModel(preview: true)
            let root: AnyView
            if ProcessInfo.processInfo.arguments.contains("--preview-profile"), let server = previewModel.current {
                root = AnyView(UserProfileView(server: server, recorded: server.snapshot.you))
            } else { root = AnyView(ContentView(model: previewModel)) }
            let view = NSHostingView(rootView: root
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

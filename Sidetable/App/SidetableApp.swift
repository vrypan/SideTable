import SwiftUI
import AppKit
import UserNotifications

@main
struct SidetableApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel(preview: ProcessInfo.processInfo.arguments.contains("--preview"))
    var body: some Scene {
        WindowGroup("Sidetable") {
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
    weak var model: AppModel?
    private var previewWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--render-preview"), ProcessInfo.processInfo.arguments.count > index + 1 {
            let path = ProcessInfo.processInfo.arguments[index + 1]
            let view = NSHostingView(rootView: ContentView(model: AppModel(preview: true)).environment(\.colorScheme, .dark).padding(.top, 28))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 740), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Sidetable Preview"; window.contentView = view
            window.appearance = NSAppearance(named: .darkAqua)
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
        if model?.servers.contains(where: { $0.files.values.contains { !$0.isEmpty } }) == true {
            let alert = NSAlert(); alert.messageText = "Quit with unsent attachments?"
            alert.informativeText = "Message text is saved. Staged attachments will need to be selected again."
            alert.addButton(withTitle: "Keep Sidetable Open"); alert.addButton(withTitle: "Quit")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        model?.saveDrafts(); return .terminateNow
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

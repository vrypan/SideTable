import SwiftUI
import AppKit
import ApronCore

struct AddServerView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Add a server", systemImage: "network").font(.title2.weight(.semibold))
            Text("Enter the address of your Apron community.").foregroundStyle(.secondary)
            TextField("server.apron.chat", text: $address).textFieldStyle(.roundedBorder).accessibilityIdentifier("serverAddress")
                .onSubmit(connect)
            Text("Use the full URL when your server requires a path, such as wss://chat.example/ws.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(userText: error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Try Apron’s public server") { address = "wss://server.apron.chat/" }.buttonStyle(.link)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Connect", action: connect).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(address.isEmpty)
            }
        }.padding(28).frame(width: 480)
    }
    private func connect() {
        do { try model.addServer(address); dismiss() } catch { self.error = error.localizedDescription }
    }
}

import ApronCore
import SwiftUI

struct RequestCooldownView: View {
    let snapshot: SessionSnapshot
    let method: String
    var hasUploads = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let cooldown = snapshot.cooldown(for: method, hasUploads: hasUploads, now: context.date) {
                Label(Self.label(cooldown, method: method, now: context.date), systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("requestCooldown")
            }
        }
    }
    static func label(_ cooldown: RequestCooldown, method: String, now: Date) -> String {
        let seconds = cooldown.remainingSeconds(at: now)
        let duration = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
        let action = cooldown.scope == .upload ? "upload" : ["message", "command"].contains(method) ? "send" : ["history", "room_list"].contains(method) ? "load again" : "try again"
        return "You can \(action) in \(duration)."
    }
}

struct CooldownButton<Label: View>: View {
    let snapshot: SessionSnapshot
    let method: String
    var hasUploads = false
    var disabled = false
    let action: () -> Void
    @ViewBuilder var label: () -> Label
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Button(action: action, label: label)
                .disabled(disabled || snapshot.cooldown(for: method, hasUploads: hasUploads, now: context.date) != nil)
        }
    }
}

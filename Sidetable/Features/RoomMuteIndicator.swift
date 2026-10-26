import SwiftUI
import ApronCore

struct RoomMuteCountdown {
    let end: Date
    let scope: String
    let now: Date
    var indefinite: Bool { end == .distantFuture }
    var remaining: TimeInterval { max(0, end.timeIntervalSince(now)) }
    var label: String {
        if indefinite { return "∞" }
        let minutes = ceil(remaining / 60)
        if minutes < 60 { return "\(max(1, minutes).formatted(.number.precision(.fractionLength(0))))m" }
        let hours = ceil(minutes / 60)
        if hours < 24 { return "\(hours.formatted(.number.precision(.fractionLength(0))))h" }
        return "\(ceil(hours / 24).formatted(.number.precision(.fractionLength(0))))d"
    }
    var detail: String {
        let subject = scope.isEmpty ? "All notifications muted" : "Room notifications muted"
        if indefinite { return subject + " until resumed" }
        return subject + " until " + end.formatted(date: .abbreviated, time: .shortened)
    }

    static func active(snapshot: SessionSnapshot, room: String, parent: String?, now: Date) -> Self? {
        // The longest applicable mute determines when this conversation can notify again.
        let scopes = Set(["", room] + (parent.map { [$0] } ?? []))
        guard let scope = scopes.sorted().filter({ (snapshot.mutedUntil[$0] ?? .distantPast) > now })
            .max(by: { snapshot.mutedUntil[$0]! < snapshot.mutedUntil[$1]! }),
              let end = snapshot.mutedUntil[scope] else { return nil }
        return Self(end: end, scope: scope, now: now)
    }
}

struct RoomMuteIndicator: View {
    let snapshot: SessionSnapshot
    let room: String
    var parent: String? = nil

    var body: some View {
        if RoomMuteCountdown.active(snapshot: snapshot, room: room, parent: parent, now: .now) != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let mute = RoomMuteCountdown.active(snapshot: snapshot, room: room, parent: parent, now: context.date) {
                    HStack(spacing: 4) {
                        Image(systemName: "bell.slash")
                            .symbolRenderingMode(.monochrome)
                            .font(.system(size: 11)).frame(width: 14)
                        Text(mute.label).font(.system(size: 10, weight: .medium))
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                            .frame(width: 26, alignment: .trailing)
                    }
                    .frame(width: 44, height: 16, alignment: .trailing)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .help(mute.detail)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(mute.detail)
                    .accessibilityValue(mute.indefinite ? "Indefinite" : mute.label + " remaining")
                    .accessibilityIdentifier("roomMuteTimer-" + room)
                }
            }
        }
    }
}

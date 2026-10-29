import SwiftUI
import AppKit
import ApronCore
import UniformTypeIdentifiers

struct AvatarView: View {
    let name: String
    var size: CGFloat = 34
    var source: String?
    var endpoint: URL?
    let cache: AvatarCache
    @State private var entry: AvatarEntry?
    private var hue: Double { Double(name.utf8.reduce(UInt32(0)) { ($0 &* 31) &+ UInt32($1) } % 360) / 360 }
    private var requestID: String { "\(endpoint?.absoluteString ?? "")|\(source ?? "")|\(cache.generation)" }
    var body: some View {
        ZStack {
            if entry?.source == source, let image = entry?.image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Text(userText: name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased())
                    .font(.system(size: size * 0.33, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(hue: hue, saturation: 0.45, brightness: 0.7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(hue: hue, saturation: 0.25, brightness: 0.8).opacity(0.18))
            }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.3))
            .accessibilityHidden(true)
            .task(id: requestID) {
                entry = nil
                guard let source, let endpoint else { return }
                entry = cache.entry(source: source, endpoint: endpoint)
            }
    }
}

/// Stands in for an untitled private room's title, ahead of the participant names.
struct ParticipantAvatars: View {
    let participants: [UserProfile]
    var size: CGFloat = 18
    let server: ServerModel
    var body: some View {
        HStack(spacing: -size * 0.25) {
            ForEach(participants.prefix(3), id: \.id) { profile in
                AvatarView(name: profile.name, size: size, source: profile.avatar, endpoint: URL(string: server.profile.address), cache: server.avatars)
            }
        }
    }
}

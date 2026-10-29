import SwiftUI
import AppKit
import ApronCore

struct WelcomeView: View {
    var connect: () -> Void
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 48, weight: .light)).foregroundStyle(.tint).padding(24)
                .background(.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 28))
            VStack(spacing: 9) {
                Text("A little space to talk.").font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("Your communities. Your servers. At home on your Mac.")
                    .font(.title3).foregroundStyle(.secondary)
            }
            Button("Add an Apron Server…", action: connect).buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 8)
            Text("Connect to any compatible Apron server.").font(.caption).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

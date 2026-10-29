import SwiftUI
import AppKit
import ApronCore

struct SignInView: View {
    @Bindable var model: AppModel
    @Bindable var server: ServerModel
    @State private var name = ""
    @State private var token = ""
    @State private var email = ""
    @State private var code = ""
    @State private var externalCode = ""
    @State private var tokenExpanded: Bool?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                AvatarView(name: server.displayTitle, size: 56, source: server.serverAvatar, endpoint: URL(string: server.profile.address), cache: server.avatars)
                Text(userText: server.displayTitle).font(.title.weight(.semibold))
                Text(userText: server.profile.address).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let description = server.serverDescription { MarkdownMessageView(source: description, size: 13, endpoint: server.profile.address, emojiStore: server.emojis) }
                if let welcome = server.snapshot.server.string("welcome") { MarkdownMessageView(source: welcome, size: 13, endpoint: server.profile.address, emojiStore: server.emojis) }
                let schemes = Set(server.snapshot.server.strings("auth") + server.snapshot.server.strings("signup"))
                let saved = model.savedAccounts(server)
                if !saved.isEmpty {
                    GroupBox(saved.count == 1 ? "Saved account" : "Saved accounts") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Accounts you signed out of on this Mac stay saved until you forget them.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(saved, id: \.self) { account in
                                HStack {
                                    Button("Continue as @\(account)") { model.continueAs(account, server: server) }
                                        .buttonStyle(.borderedProminent).accessibilityIdentifier("continueAs-" + account)
                                    Button("Forget") { model.forgetSavedAccount(account, server: server) }
                                        .help("Remove @\(account)’s saved sign-in from Keychain")
                                }
                            }
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if schemes.contains("guest") {
                    GroupBox("Join as a guest") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Display name", text: $name).textFieldStyle(.roundedBorder)
                            Text("Guest identities may change after reconnecting.").font(.caption).foregroundStyle(.secondary)
                            Button("Continue as Guest") { model.signIn(server, scheme: "guest", fields: ["name": .string(name)]) }
                                .buttonStyle(.borderedProminent).accessibilityIdentifier("guestSignIn")
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if schemes.contains("email") {
                    GroupBox("Sign in with email") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Email address", text: $email).textFieldStyle(.roundedBorder)
                            Button(server.snapshot.pendingSignIn == "email" ? "Send a New Code" : "Send Code") { code = ""; model.requestEmail(email, server: server) }.disabled(email.isEmpty)
                            if server.snapshot.pendingSignIn == "email" {
                                TextField("Code from your email", text: $code).textFieldStyle(.roundedBorder)
                                Button("Verify Code") { model.signIn(server, scheme: "email", fields: ["token": .string(code)]) }.disabled(code.isEmpty)
                            }
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if schemes.contains("external"), server.snapshot.server["apron"] == .number(9) {
                    GroupBox("Sign in with your browser") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Sign in or create an account on the server’s website, then enter the code it shows here.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Open Sign-in Page") {
                                externalCode = ""; model.requestExternalSignIn(server: server)
                            }
                            if server.snapshot.pendingSignIn == "external" {
                                SecureField("Code from the website", text: $externalCode).textFieldStyle(.roundedBorder)
                                Button("Verify Code") {
                                    model.signIn(server, scheme: "external", fields: ["token": .string(externalCode.trimmingCharacters(in: .whitespacesAndNewlines))])
                                    externalCode = ""
                                }.disabled(externalCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                Text("Use only a code from the page you opened here. If the connection is lost, open a new sign-in page.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if schemes.contains("token") {
                    // Expand when a token is the only way to get a full account.
                    let tokenOnly = !schemes.contains("email") && !(schemes.contains("external") && server.snapshot.server["apron"] == .number(9))
                    DisclosureGroup("Sign in with a token", isExpanded: Binding(get: { tokenExpanded ?? tokenOnly }, set: { tokenExpanded = $0 })) {
                        VStack(alignment: .leading, spacing: 10) {
                            if SignInToken.isPublicServer(server.profile.address) {
                                Text("To get a token for Apron’s public server:").font(.caption).foregroundStyle(.secondary)
                                Text("1. Open web.apron.chat and sign in, or create an account with a passkey.\n2. In any room, send `/invite-device mac` (any name works).\n3. Paste the token or the sign-in link from the reply here.")
                                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                Link("Open web.apron.chat", destination: URL(string: "https://web.apron.chat/")!)
                            } else {
                                Text("Your server provides tokens. On many Apron servers, sign in on the server’s website and send `/invite-device <name>`; the reply contains a token and a sign-in link.")
                                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            SecureField("Token or sign-in link", text: $token).textFieldStyle(.roundedBorder).onSubmit(signInWithToken)
                            Button("Sign In", action: signInWithToken).disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }.padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if schemes.contains("webauthn") {
                    Label("Native passkeys are not available in this build. Browser sign-in can use a website passkey when the server offers it.", systemImage: "key")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if schemes.isDisjoint(with: ["guest", "email", "token"]) && !(schemes.contains("external") && server.snapshot.server["apron"] == .number(9)) {
                    Text("This server does not offer a sign-in method supported by this build.").foregroundStyle(.orange)
                }
                if server.busy { ProgressView().controlSize(.small) }
            }.disabled(server.busy).padding(36).frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
        }
    }
    private func signInWithToken() {
        do {
            let value = try SignInToken.parse(token, endpoint: server.profile.address)
            guard !value.isEmpty else { return }
            model.signIn(server, scheme: "token", fields: ["token": .string(value)])
        } catch { server.error = error.localizedDescription }
        token = ""
    }
}

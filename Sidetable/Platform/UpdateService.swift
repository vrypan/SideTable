import AppKit
import Combine
import Sparkle

/// One updater per application. Development and preview builds never start it.
@MainActor final class UpdateService: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var error: String?
    let enabled: Bool
    private var controller: SPUStandardUpdaterController?

    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:],
         arguments: [String] = ProcessInfo.processInfo.arguments,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        enabled = Self.isEnabled(info: info, arguments: arguments, environment: environment)
    }

    static func isEnabled(info: [String: Any], arguments: [String], environment: [String: String]) -> Bool {
        guard info["SideTableDistribution"] as? Bool == true,
              !arguments.contains(where: { $0.hasPrefix("--preview") || $0 == "--render-preview" }),
              environment["XCTestConfigurationFilePath"] == nil,
              let text = info["SUFeedURL"] as? String, let url = URLComponents(string: text),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              let key = info["SUPublicEDKey"] as? String, Data(base64Encoded: key)?.count == 32 else { return false }
        return true
    }

    func start() {
        guard enabled, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main).assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main).assign(to: &$automaticallyChecks)
        do { try controller.updater.start() }
        catch { self.error = error.localizedDescription }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecks(_ value: Bool) {
        controller?.updater.automaticallyChecksForUpdates = value
    }
}

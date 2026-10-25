import Foundation
import Testing
@testable import Sidetable

@MainActor @Test func updatesOnlyStartForConfiguredDistributionBuilds() {
    let configured: [String: Any] = ["SideTableDistribution": true,
        "SUFeedURL": "https://github.com/vrypan/SideTable/releases/latest/download/appcast.xml",
        "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString()]
    #expect(UpdateService.isEnabled(info: configured, arguments: [], environment: [:]))
    for args in [["--preview"], ["--render-preview", "/tmp/image.png"], ["--preview-sign-in"]] {
        #expect(!UpdateService.isEnabled(info: configured, arguments: args, environment: [:]))
    }
    #expect(!UpdateService.isEnabled(info: configured, arguments: [], environment: ["XCTestConfigurationFilePath": "test"]))
    for patch: [String: Any] in [["SideTableDistribution": false], ["SUPublicEDKey": "invalid"],
                                ["SUFeedURL": "http://example.com/feed.xml"],
                                ["SUFeedURL": "https://name:secret@example.com/feed.xml"]] {
        #expect(!UpdateService.isEnabled(info: configured.merging(patch) { _, new in new }, arguments: [], environment: [:]))
    }
    let disabled = UpdateService(info: [:], arguments: [], environment: [:])
    disabled.start()
    #expect(!disabled.enabled)
    #expect(!disabled.canCheckForUpdates)
    #expect(disabled.error == nil)
}

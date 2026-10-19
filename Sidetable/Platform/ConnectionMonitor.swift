import AppKit
import Network

/// Combines workspace sleep with path availability so waking while offline cannot
/// reconnect prematurely. An initial path report only changes availability once.
struct ConnectionAvailability {
    var awake = true
    var networkAvailable = true
    var canConnect: Bool { awake && networkAvailable }
}

@MainActor
final class ConnectionMonitor: NSObject {
    private let monitor = NWPathMonitor()
    private var availability = ConnectionAvailability()
    private let changed: @MainActor (Bool) -> Void

    init(changed: @escaping @MainActor (Bool) -> Void) {
        self.changed = changed
        super.init()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(waking), name: NSWorkspace.didWakeNotification, object: nil)
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in self?.update(network: available) }
        }
        monitor.start(queue: DispatchQueue(label: "chat.sidetable.connection-monitor"))
    }
    @objc private func sleeping(_ notification: Notification) { update(awake: false) }
    @objc private func waking(_ notification: Notification) { update(awake: true) }
    private func update(awake: Bool? = nil, network: Bool? = nil) {
        let previous = availability.canConnect
        if let awake { availability.awake = awake }
        if let network { availability.networkAvailable = network }
        if previous != availability.canConnect { changed(availability.canConnect) }
    }
    func stop() {
        monitor.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}

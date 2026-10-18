import Foundation
import Network

/// Wraps NWPathMonitor: calls `onChange(true)` when a network route exists and
/// `onChange(false)` when there is none. "Available" means a route exists, not that the
/// broker is reachable, which is the right signal for a broker on the local network.
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "macha.network")

    /// `onChange` runs on a private queue, once at start and then on every path change.
    func start(onChange: @escaping (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in
            onChange(path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}

import AppKit
import CoreWLAN
import Foundation
import Network

/// Watches the Mac's connectivity: network changes, sleep and wake.
///
/// ConnectionManager depends on this for when to reconnect, so it always runs (`alwaysRuns`),
/// even when its sensor is not enabled. The Wi-Fi name is an extra, for Home Assistant.
///
/// "Available" means a route exists, not that the broker is reachable, which is the right signal
/// for a broker on the local network.
///
/// ## Reading the Wi-Fi name
/// macOS hides it unless the process has Location Services permission (granted by `macha configure`)
/// AND is an AppKit application. A plain command-line process gets nothing even with permission,
/// so `activateApp()` registers macha as a background app (no Dock icon, no menu).
final class NetworkSensorSource: NSObject, SensorSource, CWEventDelegate {
    /// The Wi-Fi network name, "Not connected" when there is none, or "Unknown" when the Mac is
    /// on Wi-Fi but macOS won't say which (no Location Services permission).
    static let ssid = Sensor(
        id: "network_ssid",
        name: "Wi-Fi network",
        component: .sensor,
        icon: "mdi:wifi"
    )

    static let sensors = [ssid]
    static let alwaysRuns = true

    static let notConnected = "Not connected"
    static let unknown = "Unknown"

    private let manager: ConnectionManager
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "macha.network")
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    init(manager: ConnectionManager) {
        self.manager = manager
        super.init()
    }

    /// Makes this process an AppKit app, which macOS requires before it will reveal the Wi-Fi name.
    /// Main thread only. Safe to call more than once.
    static func activateApp() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    /// The Wi-Fi name, `notConnected`, or `unknown` (on Wi-Fi, but macOS won't say which network).
    static func currentSSID() -> String {
        let wifi = CWWiFiClient.shared().interface()
        if let name = wifi?.ssid() { return name }
        if let wifi, wifi.powerOn(), wifi.rssiValue() != 0 { return unknown }
        return notConnected
    }

    func start() {
        if manager.config.isEnabled(Self.ssid) { Self.activateApp() }

        // Called on a private queue: once at start, then on every path change.
        monitor.pathUpdateHandler = { [weak self] path in self?.pathChanged(path) }
        monitor.start(queue: queue)

        // Moving between two Wi-Fi networks doesn't always change the path.
        let wifi = CWWiFiClient.shared()
        wifi.delegate = self
        try? wifi.startMonitoringEvent(with: .ssidDidChange)

        // Safety net: Location permission can arrive after startup, which fires no network event.
        // Unchanged values are not resent.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.publishSSID()
        }

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.manager.willSleep()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.manager.didWake()
        })
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        monitor.cancel()
        try? CWWiFiClient.shared().stopMonitoringAllEvents()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    private func pathChanged(_ path: NWPath) {
        manager.networkChanged(available: path.status == .satisfied)
        publishSSID()
    }

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        publishSSID()
    }

    private func publishSSID() {
        guard manager.config.isEnabled(Self.ssid) else { return }
        DispatchQueue.main.async {
            let name = Self.currentSSID()
            self.manager.send(name, for: Self.ssid)
            if name == Self.unknown {
                Log.info("network: can't read the Wi-Fi name; allow macha in System Settings > Privacy & Security > Location Services (`macha configure` asks)",
                         key: "ssid-permission", every: .infinity)
            }
        }
    }
}

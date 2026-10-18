import Foundation

/// Reports Bluetooth state to Home Assistant, without interpreting it:
///  - "Bluetooth connected devices": state = how many paired devices are connected,
///    attributes = `devices` (names of the connected ones) and `paired` (names of all paired)
/// What the devices are (headphones, a keyboard, ...) is for Home Assistant to work out.
///
/// Event-driven through BluetoothWatcher, with a slow safety-net timer.
final class BluetoothSensorSource: SensorSource {
    static let devices = Sensor(
        id: "bluetooth_devices",
        name: "Bluetooth connected devices",
        component: .sensor,
        icon: "mdi:bluetooth-connect",
        stateClass: "measurement",
        hasAttributes: true
    )

    static let sensors = [devices]

    private let manager: ConnectionManager
    private var watcher: BluetoothWatcher?
    private var timer: Timer?

    init(manager: ConnectionManager) {
        self.manager = manager
    }

    func start() {
        let watcher = BluetoothWatcher { [weak self] snapshot in
            self?.handle(snapshot)
        }
        self.watcher = watcher
        watcher.start()   // reports the initial state through the closure above

        // Safety net, and picks up newly paired devices (which have no event of their own).
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak watcher] _ in
            watcher?.reconcile()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        watcher?.stop()
        watcher = nil
    }

    /// Decide what to send whenever the Bluetooth snapshot changes.
    private func handle(_ snapshot: BluetoothWatcher.Snapshot) {
        manager.send(
            String(snapshot.connected.count),
            attributes: ["devices": snapshot.connected, "paired": snapshot.paired],
            for: Self.devices
        )
    }
}

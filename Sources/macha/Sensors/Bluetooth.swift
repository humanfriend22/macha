import Foundation
import IOBluetooth

/// Reports Bluetooth state to Home Assistant, without interpreting it:
///  - "Bluetooth connected devices": state = how many paired devices are connected,
///    attributes = `connected` (names of the connected ones) and `paired` (names of all paired)
/// What the devices are (headphones, a keyboard, ...) is for Home Assistant to work out.
///
/// Event-driven, with a slow safety-net timer.
///
/// IMPORTANT: IOBluetooth delivers callbacks on the thread that registered them, and only
/// while that thread's run loop is running. `start()` is called on the main thread and the
/// process stays alive with RunLoop.main.run().
final class BluetoothSensorSource: NSObject, SensorSource {
    static let devices = Sensor(
        id: "bluetooth_devices",
        name: "Bluetooth connected devices",
        component: .sensor,
        icon: "mdi:bluetooth-connect",
        stateClass: "measurement",
        hasAttributes: true
    )

    static let sensors = [devices]

    struct Snapshot: Equatable {
        /// Names of paired devices that are currently connected, sorted.
        var connected: [String]
        /// Names of all paired devices, sorted.
        var paired: [String]
    }

    /// Current state, read straight from the system (used by `macha status` and `doctor`).
    static func snapshot() -> Snapshot {
        let devices = pairedDevices()
        return Snapshot(
            connected: devices.filter { $0.isConnected() }.map(name).sorted(),
            paired: devices.map(name).sorted()
        )
    }

    private let manager: ConnectionManager
    private var connectNotification: IOBluetoothUserNotification?
    /// Disconnect notifications are per-device, keyed by address.
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var last: Snapshot?
    private var timer: Timer?

    init(manager: ConnectionManager) {
        self.manager = manager
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        // Fires whenever ANY Bluetooth device connects.
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:fromDevice:))
        )
        // Disconnects can only be observed per device, so watch every paired device.
        watchDisconnects(of: Self.pairedDevices())
        publishIfChanged()

        // Safety net, and picks up newly paired devices (which have no event of their own).
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.reconcile()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        connectNotification?.unregister()
        connectNotification = nil
        disconnectNotifications.values.forEach { $0.unregister() }
        disconnectNotifications.removeAll()
    }

    private func reconcile() {
        watchDisconnects(of: Self.pairedDevices())   // picks up newly paired devices
        publishIfChanged()
    }

    // MARK: - Callbacks (selectors are called by IOBluetooth with these two arguments)

    @objc private func deviceConnected(
        _ notification: IOBluetoothUserNotification,
        fromDevice device: IOBluetoothDevice
    ) {
        watchDisconnects(of: [device])   // a device we haven't seen before may disconnect later
        publishIfChanged()
    }

    @objc private func deviceDisconnected(
        _ notification: IOBluetoothUserNotification,
        fromDevice device: IOBluetoothDevice
    ) {
        publishIfChanged()
        // isConnected() may still read true for a moment inside the callback (unverified),
        // so check once more shortly after.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.publishIfChanged()
        }
    }

    // MARK: - Helpers

    private func watchDisconnects(of devices: [IOBluetoothDevice]) {
        for device in devices {
            guard let address = device.addressString, disconnectNotifications[address] == nil else { continue }
            disconnectNotifications[address] = device.register(
                forDisconnectNotification: self,
                selector: #selector(deviceDisconnected(_:fromDevice:))
            )
        }
    }

    /// Sends the state to Home Assistant, only when it differs from the last one.
    private func publishIfChanged() {
        let snapshot = Self.snapshot()
        guard snapshot != last else { return }
        last = snapshot
        manager.send(
            String(snapshot.connected.count),
            attributes: ["connected": snapshot.connected, "paired": snapshot.paired],
            for: Self.devices
        )
    }

    private static func pairedDevices() -> [IOBluetoothDevice] {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    }

    private static func name(_ device: IOBluetoothDevice) -> String {
        device.nameOrAddress ?? "Unknown"
    }
}

import Foundation
import IOBluetooth

/// Watches Bluetooth connect/disconnect events and reports which paired devices are connected.
///
/// IMPORTANT: IOBluetooth delivers callbacks on the thread that registered them, and only
/// while that thread's run loop is running. Create and start this on the main thread and
/// keep the process alive with RunLoop.main.run() (or dispatchMain()).
public final class BluetoothWatcher: NSObject {
    public struct Snapshot: Equatable {
        /// Names of paired devices that are currently connected, sorted.
        public var connected: [String]
        /// Names of all paired devices, sorted.
        public var paired: [String]
    }

    private let onChange: (Snapshot) -> Void
    private var connectNotification: IOBluetoothUserNotification?
    /// Disconnect notifications are per-device, keyed by address.
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var last: Snapshot?

    /// `onChange` runs on the main thread, only when the snapshot differs from the last one.
    public init(onChange: @escaping (Snapshot) -> Void) {
        self.onChange = onChange
        super.init()
    }

    // MARK: - Lifecycle

    public func start() {
        // Fires whenever ANY Bluetooth device connects.
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:fromDevice:))
        )
        // Disconnects can only be observed per device, so watch every paired device.
        watchDisconnects(of: pairedDevices())
        publishIfChanged()
    }

    public func stop() {
        connectNotification?.unregister()
        connectNotification = nil
        disconnectNotifications.values.forEach { $0.unregister() }
        disconnectNotifications.removeAll()
    }

    /// Re-read state and publish if it changed. Call from a slow timer as a safety net.
    public func reconcile() {
        watchDisconnects(of: pairedDevices())   // picks up newly paired devices
        publishIfChanged()
    }

    /// Current state without publishing (useful for a `status` command).
    public func currentSnapshot() -> Snapshot {
        let devices = pairedDevices()
        return Snapshot(
            connected: devices.filter { $0.isConnected() }.map(Self.name).sorted(),
            paired: devices.map(Self.name).sorted()
        )
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

    private func pairedDevices() -> [IOBluetoothDevice] {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    }

    private func watchDisconnects(of devices: [IOBluetoothDevice]) {
        for device in devices {
            guard let address = device.addressString, disconnectNotifications[address] == nil else { continue }
            disconnectNotifications[address] = device.register(
                forDisconnectNotification: self,
                selector: #selector(deviceDisconnected(_:fromDevice:))
            )
        }
    }

    private func publishIfChanged() {
        let snapshot = currentSnapshot()
        guard snapshot != last else { return }
        last = snapshot
        onChange(snapshot)
    }

    private static func name(_ device: IOBluetoothDevice) -> String {
        device.nameOrAddress ?? "Unknown"
    }
}

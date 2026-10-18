import Foundation

/// Watches one kind of system event (Bluetooth changes, power state, ...) and reports the
/// sensors it feeds through the ConnectionManager.
///
/// To add one: write a `final class` that conforms to this, then list it in `SensorSources.all`.
/// A source is a class because macOS callbacks need an object to call back into.
/// `start()` and `stop()` are called on the main thread, with the main run loop running.
protocol SensorSource: AnyObject {
    /// Every sensor this source can report. Hardcoded: it's what `macha configure` offers.
    static var sensors: [Sensor] { get }

    init(manager: ConnectionManager)

    /// Begin watching, and report the initial state with `manager.send`.
    /// Report everything; the manager drops sensors that aren't enabled.
    func start()
    /// Stop watching and release anything held (notifications, timers).
    func stop()
}

/// Every source macha knows about.
enum SensorSources {
    static let all: [any SensorSource.Type] = [
        BluetoothSensorSource.self,
    ]

    /// Every sensor in this version of macha, in the order `macha configure` asks about them.
    static var sensors: [Sensor] { all.flatMap { $0.sensors } }
}

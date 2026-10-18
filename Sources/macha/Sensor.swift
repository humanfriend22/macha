import Foundation

/// One sensor on the Home Assistant dashboard (what HA calls a sensor or binary_sensor).
/// Sensors are built into the binary: each SensorSource declares the ones it can report,
/// and `enabled_sensors` in the config picks which of them are actually sent.
struct Sensor {
    /// The Home Assistant entity types macha publishes. The broker ACL must list exactly these
    /// (see ConnectionManager.sweepStaleSensors), so adding a case means updating the ACL.
    enum Component: String, CaseIterable {
        case sensor
        case binarySensor = "binary_sensor"
        case deviceTracker = "device_tracker"
    }

    /// Stable ID, unique across all sensors. Used in config.json, topics and unique_ids,
    /// so never rename one.
    let id: String
    /// What Home Assistant shows.
    let name: String
    let component: Component
    var deviceClass: String? = nil     // e.g. "connectivity"
    var unit: String? = nil            // e.g. "%"
    var icon: String? = nil            // e.g. "mdi:headphones"
    var stateClass: String? = nil      // e.g. "measurement"
    /// False for entities that only have attributes (a device_tracker gets its position from them).
    var hasState = true
    /// True if the source also sends attributes (a JSON object) for this sensor.
    var hasAttributes = false
}

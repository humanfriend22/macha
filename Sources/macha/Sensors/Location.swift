import CoreLocation
import Foundation

/// Reports where the Mac is, as a Home Assistant device tracker: HA works out zones (home, work)
/// from the coordinates.
///
/// Needs Location Services permission for macha (System Settings > Privacy & Security > Location
/// Services). `macha configure` asks for it, because a background service has no way to show the prompt.
///
/// IMPORTANT: CLLocationManager delivers callbacks on the thread that created it, so it must be
/// created on the main thread, which `start()` and `authorizationStatus` are.
final class LocationSensorSource: NSObject, SensorSource, CLLocationManagerDelegate {
    static let location = Sensor(
        id: "location",
        name: "Location",
        component: .deviceTracker,
        icon: "mdi:laptop",
        hasState: false,
        hasAttributes: true
    )

    static let sensors = [location]

    /// The current permission. With `asking`, shows the prompt first if macOS hasn't asked yet
    /// (waits up to a minute for the answer). A new CLLocationManager reports "not asked yet" for a
    /// moment before it learns the real answer, so this waits for that too. Main thread only.
    static func authorizationStatus(asking: Bool = false) -> CLAuthorizationStatus {
        let manager = CLLocationManager()
        func wait(up seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while manager.authorizationStatus == .notDetermined, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            }
        }
        wait(up: 1.5)
        if asking, manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
            wait(up: 60)
        }
        return manager.authorizationStatus
    }

    static func describe(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not asked yet"
        case .restricted: return "restricted by the system"
        case .denied: return "denied"
        default: return "allowed"
        }
    }

    private let manager: ConnectionManager
    private var locationManager: CLLocationManager?

    init(manager: ConnectionManager) {
        self.manager = manager
        super.init()
    }

    func start() {
        let location = CLLocationManager()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyHundredMeters
        location.distanceFilter = 100   // meters: a Mac that stays put sends nothing
        locationManager = location   // the delegate is told the current permission right away
    }

    func stop() {
        locationManager?.stopUpdatingLocation()
        locationManager = nil
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ location: CLLocationManager) {
        switch location.authorizationStatus {
        case .notDetermined:
            // Often no prompt can appear for a background service; `macha configure` asks instead.
            Log.info("location: no permission yet, run `macha configure` to grant it", key: "location-permission", every: .infinity)
            location.requestWhenInUseAuthorization()
        case .denied, .restricted:
            Log.info("location: access is \(Self.describe(location.authorizationStatus)); enable macha in System Settings > Privacy & Security > Location Services",
                     key: "location-permission", every: .infinity)
        default:
            Log.reset(key: "location-permission")
            location.startUpdatingLocation()
        }
    }

    func locationManager(_ location: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let newest = locations.last else { return }
        manager.send(
            nil,
            attributes: [
                "latitude": newest.coordinate.latitude,
                "longitude": newest.coordinate.longitude,
                "gps_accuracy": newest.horizontalAccuracy,
            ],
            for: Self.location
        )
    }

    func locationManager(_ location: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown just means "no fix yet"; CoreLocation keeps trying.
        guard (error as? CLError)?.code != .locationUnknown else { return }
        Log.info("location: \(error.localizedDescription)", key: "location-error", every: 3600)
    }
}

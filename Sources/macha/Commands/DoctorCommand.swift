import ArgumentParser
import CoreLocation
import Foundation

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check the config, Bluetooth access and the MQTT broker."
    )

    func run() throws {
        var failed = false
        func pass(_ message: String) { print("✓ \(message)") }
        func warn(_ message: String) { print("! \(message)") }
        func fail(_ message: String) { failed = true; print("✗ \(message)") }

        // 1. Config
        let config: Config
        do {
            config = try Config.load()
            pass("Config loaded from \(Config.path)")
            print("  \(config.redactedDescription)")
        } catch {
            fail(error.localizedDescription)
            throw ExitCode.failure
        }

        if Config.hasLoosePermissions() {
            warn("Config file is readable by other users. Run: chmod 600 \(Config.path)")
        }

        if !config.unknownSensorIDs.isEmpty {
            warn("Unknown sensors will be ignored: \(config.unknownSensorIDs.joined(separator: ", ")). Run `macha configure` to see the available ones.")
        }
        pass("Sending: \(config.enabledSensors.map(\.name).joined(separator: ", "))")

        // 2. Bluetooth
        let snapshot = BluetoothSensorSource.snapshot()
        if snapshot.paired.isEmpty {
            warn("No paired Bluetooth devices visible. If you have some, access may be denied (System Settings > Privacy & Security > Bluetooth).")
        } else {
            pass("Bluetooth: \(snapshot.paired.count) paired, \(snapshot.connected.count) connected")
        }

        // Location, only if the sensor is on
        if config.isEnabled(LocationSensorSource.location) {
            let status = LocationSensorSource.authorizationStatus()
            if status == .authorizedAlways {
                pass("Location access allowed")
            } else {
                warn("Location access is \(LocationSensorSource.describe(status)). Run `macha configure` or enable it in System Settings > Privacy & Security > Location Services.")
            }
        }

        // Wi-Fi name, only if the sensor is on
        if config.isEnabled(NetworkSensorSource.ssid) {
            NetworkSensorSource.activateApp()
            let name = NetworkSensorSource.currentSSID()
            if name == NetworkSensorSource.unknown {
                warn("Wi-Fi name can't be read: allow Location access (run `macha configure`).")
            } else {
                pass("Wi-Fi: \(name)")
            }
        }

        // 3. Broker, through the same ConnectionManager the agent uses (with its own client ID,
        //    so a running agent is never kicked off the broker).
        let manager = ConnectionManager(config: config, clientID: "macha-doctor-\(UUID().uuidString.prefix(8))")
        if let error = manager.probe() {
            fail("Could not connect to \(config.url): \(error.localizedDescription)")
            print("  Check the URL (and the nginx /mqtt route behind it), and the username and password.")
        } else {
            pass("Connected to broker \(config.url)")
        }
        manager.shutdown()

        if failed { throw ExitCode.failure }
    }
}

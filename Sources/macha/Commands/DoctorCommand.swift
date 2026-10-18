import ArgumentParser
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

        let known = SensorSources.sensors
        let unknown = config.enabledSensors.filter { id in !known.contains { $0.id == id } }
        if !unknown.isEmpty {
            warn("Unknown sensors will be ignored: \(unknown.joined(separator: ", ")). Run `macha configure` to see the available ones.")
        }
        let enabledNames = known.filter { config.enabledSensors.contains($0.id) }.map(\.name)
        pass("Sending: \(enabledNames.joined(separator: ", "))")

        // 2. Bluetooth
        let snapshot = BluetoothWatcher { _ in }.currentSnapshot()
        if snapshot.paired.isEmpty {
            warn("No paired Bluetooth devices visible. If you have some, access may be denied (System Settings > Privacy & Security > Bluetooth).")
        } else {
            pass("Bluetooth: \(snapshot.paired.count) paired, \(snapshot.connected.count) connected")
        }

        // 3. Broker, through the same ConnectionManager the agent uses (with its own client ID,
        //    so a running agent is never kicked off the broker).
        let manager = try ConnectionManager(config: config, clientID: "macha-doctor-\(UUID().uuidString.prefix(8))")
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

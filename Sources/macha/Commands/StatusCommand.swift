import ArgumentParser
import Foundation

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show paired Bluetooth devices and whether each is connected."
    )

    func run() throws {
        let snapshot = BluetoothWatcher { _ in }.currentSnapshot()

        print("Bluetooth")
        if snapshot.paired.isEmpty {
            print("  No paired devices found.")
            print("  If you have paired devices, Bluetooth access may be denied:")
            print("  System Settings > Privacy & Security > Bluetooth")
            return
        }

        for name in snapshot.paired {
            let connected = snapshot.connected.contains(name)
            print("  \(dot(connected)) \(name)")
        }
        print("")
        print("\(snapshot.connected.count) of \(snapshot.paired.count) connected")
    }

    private func dot(_ on: Bool) -> String {
        let symbol = on ? "●" : "○"
        guard isatty(STDOUT_FILENO) != 0 else { return symbol }
        return on ? "\u{1B}[32m\(symbol)\u{1B}[0m" : "\u{1B}[90m\(symbol)\u{1B}[0m"
    }
}

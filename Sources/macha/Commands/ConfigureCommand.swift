import ArgumentParser
import Foundation

struct ConfigureCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "configure",
        abstract: "Create or change the config. Press Enter to keep the value shown in parentheses."
    )

    func run() throws {
        // Read whatever is there without validating, so an old or half-finished file still
        // provides defaults (including the password).
        let existing = try? Config.load(validating: false)
        if existing != nil {
            print("Editing \(Config.path). Press Enter to keep the value in parentheses.\n")
        } else {
            print("Creating \(Config.path).\n")
        }

        let url = try ask(
            "MQTT WebSocket URL, e.g. wss://example.duckdns.org/mqtt",
            current: existing?.url,
            validate: { value in
                do {
                    _ = try Config.parseEndpoint(value)
                    return nil
                } catch ConfigError.invalid(let why) {
                    return why
                } catch {
                    return "\(error)"
                }
            }
        )

        let username = try ask(
            "Username (also names this Mac in Home Assistant)",
            current: existing?.username,
            validate: { Config.isValidUsername($0) ? nil : "Use only letters, digits, _ and - (macha uses the username in topic names)." }
        )

        let currentPassword = existing?.password
        let hint = currentPassword != nil ? "current: set" : "none set"
        let typed = String(cString: getpass("Password, hidden (\(hint)): "))
        let password: String? = typed.isEmpty ? currentPassword : typed

        // Which sensors to send. They are built into this version of macha; run configure again
        // after updating to see new ones.
        let previous = existing?.enabledSensors ?? []
        var enabled: [String] = []
        repeat {
            print("\nSensors to send to Home Assistant:")
            enabled = []
            for sensor in SensorSources.sensors {
                let answer = try ask(
                    "  Send \"\(sensor.name)\"? y/n",
                    current: previous.isEmpty ? nil : (previous.contains(sensor.id) ? "y" : "n"),
                    fallback: "y",
                    validate: { ["y", "n"].contains($0.lowercased()) ? nil : "Please answer y or n." }
                )
                if answer.lowercased() == "y" { enabled.append(sensor.id) }
            }
            if enabled.isEmpty { print("Enable at least one sensor.") }
        } while enabled.isEmpty

        let config = Config(
            url: url,
            username: username,
            password: password,
            discoveryPrefix: existing?.discoveryPrefix ?? "homeassistant",
            enabledSensors: enabled
        )
        try config.save()

        print("")
        print("Saved \(Config.path) (readable only by you).")
        print("Next: `macha doctor` to check everything, then `macha run` to try it.")
        print("If macha is already running in the background, restart it to apply the changes.")
    }

    /// Asks one question and returns the answer. Enter keeps `current`, or uses `fallback`;
    /// with neither, it asks again. `validate` returns a problem to show, or nil if the answer is fine.
    private func ask(
        _ question: String,
        current: String?,
        fallback: String? = nil,
        validate: (String) -> String? = { _ in nil }
    ) throws -> String {
        let keep = (current?.isEmpty == false) ? current : nil
        let hint: String
        if let keep { hint = "current: \(keep)" }
        else if let fallback { hint = "default: \(fallback)" }
        else { hint = "required" }

        while true {
            print("\(question) (\(hint)): ", terminator: "")
            guard let line = readLine() else {
                throw ValidationError("Input ended before configuration was finished.")
            }
            let typed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = typed.isEmpty ? (keep ?? fallback) : typed else {
                print("  This one is required.")
                continue
            }
            if let problem = validate(value) {
                print("  \(problem)")
                continue
            }
            return value
        }
    }
}

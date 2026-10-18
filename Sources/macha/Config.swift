import Foundation

/// macha's configuration, stored as JSON at ~/.config/macha/config.json.
/// Everything here is chosen with `macha configure`; the sensors themselves are built into the binary.
///
/// The `enabled_sensors` list from the file is never exposed as is. Ask for the sensors by
/// classification instead: `allowedSensors` (everything this version can send), and for a config
/// `enabledSensors`, `disabledSensors` and `unknownSensorIDs` (ids in the file this version doesn't know).
struct Config: Codable, Equatable {
    /// Full WebSocket URL of the MQTT broker, e.g. "wss://example.duckdns.org/mqtt".
    var url: String
    var username: String
    var password: String?
    var discoveryPrefix: String
    /// `enabled_sensors` as written in the file, unknown ids included.
    private var sensorIDs: [String]

    init(
        url: String,
        username: String,
        password: String? = nil,
        discoveryPrefix: String = "homeassistant",
        enabledSensors: [Sensor]
    ) {
        self.url = url
        self.username = username
        self.password = password
        self.discoveryPrefix = discoveryPrefix
        self.sensorIDs = enabledSensors.map(\.id)
    }

    private enum CodingKeys: String, CodingKey {
        case url, username, password
        case discoveryPrefix = "discovery_prefix"
        case sensorIDs = "enabled_sensors"
    }

    // Missing keys fall back to empty/default values instead of failing to decode, so an old or
    // half-finished file can still be read by `macha configure`. `validate()` reports what's missing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try c.decodeIfPresent(String.self, forKey: .password)
        discoveryPrefix = try c.decodeIfPresent(String.self, forKey: .discoveryPrefix) ?? "homeassistant"
        sensorIDs = try c.decodeIfPresent([String].self, forKey: .sensorIDs) ?? []
    }
}

// MARK: - Sensors

extension Config {
    /// Every sensor this version of macha can send: what `macha configure` offers.
    static var allowedSensors: [Sensor] { SensorSources.sensors }

    var enabledSensors: [Sensor] { Config.allowedSensors.filter(isEnabled) }
    var disabledSensors: [Sensor] { Config.allowedSensors.filter { !isEnabled($0) } }
    /// Ids in the file that this version doesn't have (removed or renamed sensors).
    var unknownSensorIDs: [String] {
        sensorIDs.filter { id in !Config.allowedSensors.contains { $0.id == id } }
    }

    func isEnabled(_ sensor: Sensor) -> Bool { sensorIDs.contains(sensor.id) }

    /// The sources `macha run` starts: those with at least one enabled sensor, and the ones macha needs itself.
    var enabledSources: [any SensorSource.Type] {
        SensorSources.all.filter { source in source.alwaysRuns || source.sensors.contains(where: isEnabled) }
    }
}

// MARK: - The broker

extension Config {
    /// `url` taken apart for the MQTT client. Only valid on a validated config: `Config.load()`
    /// and `save()` check it, and `macha configure` (which may hold an unvalidated one) only reads `url`.
    var endpoint: Endpoint {
        do { return try Endpoint(url: url) }
        catch { preconditionFailure("config was not validated: \(error.localizedDescription)") }
    }
}

// MARK: - Errors

enum ConfigError: LocalizedError {
    case notFound(String)
    case unreadable(String, underlying: Error)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let path):
            return "No config file at \(path). Run `macha configure` to create one."
        case .unreadable(let path, let err):
            return "Couldn't read config at \(path): \(err.localizedDescription)"
        case .invalid(let why):
            return "Invalid config: \(why). Run `macha configure` to fix it."
        }
    }
}

// MARK: - Location

extension Config {
    /// Hardcoded for now: ~/.config/macha/config.json
    static let path = NSHomeDirectory() + "/.config/macha/config.json"
}

// MARK: - Load / save

extension Config {
    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    /// `validating: false` is for `macha configure`, which wants to read whatever is there
    /// (even an old or incomplete file) to offer it as defaults.
    static func load(validating: Bool = true) throws -> Config {
        let file = Config.path
        guard FileManager.default.fileExists(atPath: file) else {
            throw ConfigError.notFound(file)
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: file))
        } catch {
            throw ConfigError.unreadable(file, underlying: error)
        }
        let config: Config
        do {
            config = try JSONDecoder().decode(Config.self, from: data)
        } catch {
            throw ConfigError.invalid("\(file): \(error.localizedDescription)")
        }
        if validating { try config.validate() }
        return config
    }

    /// Writes the file with 0600 permissions (it may contain the MQTT password)
    /// inside a 0700 directory. The file is created with the restrictive mode from
    /// the start, so the password is never briefly world-readable.
    func save() throws {
        try validate()
        let file = Config.path
        let dir = (file as NSString).deletingLastPathComponent
        let fm = FileManager.default

        try fm.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let data = try Config.encoder.encode(self)
        guard fm.createFile(
            atPath: file,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw ConfigError.invalid("could not write \(file)")
        }
        // createFile keeps existing permissions when overwriting, so enforce them.
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
    }

    /// For `macha doctor`: true if group/others can read the file.
    static func hasLoosePermissions() -> Bool {
        let file = Config.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file),
              let mode = attrs[.posixPermissions] as? NSNumber else { return false }
        return mode.intValue & 0o077 != 0
    }
}

// MARK: - Validation

extension Config {
    func validate() throws {
        if url.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ConfigError.invalid("`url` is missing")
        }
        do {
            _ = try Endpoint(url: url)
        } catch let problem as Endpoint.Invalid {
            throw ConfigError.invalid("`url` \(problem.reason)")
        }
        if username.isEmpty {
            throw ConfigError.invalid("`username` is missing")
        }
        if !Config.isValidUsername(username) {
            throw ConfigError.invalid("`username` may only contain letters, digits, `_` and `-`, because macha uses it in topic names")
        }
        if enabledSensors.isEmpty {
            throw ConfigError.invalid("no sensors are enabled, so there is nothing to send")
        }
    }

    /// macha files its MQTT topics under the username, and Home Assistant only accepts these characters there.
    static func isValidUsername(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// Safe to print in `doctor` or logs.
    var redactedDescription: String {
        "\(username)@\(url) (password \(password == nil ? "not set" : "set"))"
    }
}

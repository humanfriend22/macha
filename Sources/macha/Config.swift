import Foundation

/// macha's configuration, stored as JSON (snake_case keys) at ~/.config/macha/config.json.
/// Everything here is chosen with `macha configure`; the sensors themselves are built into the binary.
struct Config: Codable, Equatable {
    /// Full WebSocket URL of the MQTT broker, e.g. "wss://example.duckdns.org/mqtt".
    var url: String
    /// Also the name of this Mac in Home Assistant, and what its topics are filed under.
    var username: String
    var password: String?
    var discoveryPrefix: String
    /// IDs of the sensors to send to Home Assistant (see `SensorSources.sensors`).
    var enabledSensors: [String]

    init(
        url: String,
        username: String,
        password: String? = nil,
        discoveryPrefix: String = "homeassistant",
        enabledSensors: [String]
    ) {
        self.url = url
        self.username = username
        self.password = password
        self.discoveryPrefix = discoveryPrefix
        self.enabledSensors = enabledSensors
    }

    // Missing keys fall back to empty/default values instead of failing to decode, so an old or
    // half-finished file can still be read by `macha configure`. `validate()` reports what's missing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try c.decodeIfPresent(String.self, forKey: .password)
        discoveryPrefix = try c.decodeIfPresent(String.self, forKey: .discoveryPrefix) ?? "homeassistant"
        enabledSensors = try c.decodeIfPresent([String].self, forKey: .enabledSensors) ?? []
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
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
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
            config = try decoder.decode(Config.self, from: data)
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

// MARK: - The broker URL

/// The broker URL taken apart for the MQTT client.
struct Endpoint {
    let host: String
    /// nil means the scheme's standard port (80 for ws, 443 for wss).
    let port: Int?
    /// Path plus query exactly as given, "/" if the URL had none.
    let path: String
    let useTLS: Bool
}

extension Config {
    /// macha only speaks MQTT over WebSocket: `ws://` or `wss://`. How the URL reaches the broker
    /// (proxy, path, port) is up to whoever set the broker up.
    static func parseEndpoint(_ url: String) throws -> Endpoint {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: trimmed),
              let scheme = parts.scheme?.lowercased(), scheme == "ws" || scheme == "wss",
              let host = parts.host, !host.isEmpty else {
            throw ConfigError.invalid("`url` must be a WebSocket URL like wss://example.duckdns.org/mqtt (starting with ws:// or wss://)")
        }
        if parts.user != nil || parts.password != nil {
            throw ConfigError.invalid("`url` must not contain a username or password; they have their own settings")
        }
        let path = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
        return Endpoint(
            host: host,
            port: parts.port,
            path: parts.percentEncodedQuery.map { path + "?" + $0 } ?? path,
            useTLS: scheme == "wss"
        )
    }

    func endpoint() throws -> Endpoint { try Config.parseEndpoint(url) }
}

// MARK: - Validation

extension Config {
    func validate() throws {
        if url.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ConfigError.invalid("`url` is missing")
        }
        _ = try endpoint()
        if username.isEmpty {
            throw ConfigError.invalid("`username` is missing")
        }
        if !Config.isValidUsername(username) {
            throw ConfigError.invalid("`username` may only contain letters, digits, `_` and `-`, because macha uses it in topic names")
        }
        if enabledSensors.isEmpty {
            throw ConfigError.invalid("`enabled_sensors` is empty, so there is nothing to send")
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

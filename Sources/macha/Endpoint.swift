import Foundation

/// Where the MQTT broker is, taken apart for the MQTT client.
///
/// macha only speaks MQTT over WebSocket: `ws://` or `wss://`. How the URL reaches the broker
/// (proxy, path, port) is up to whoever set the broker up.
struct Endpoint: Equatable {
    let host: String
    /// nil means the scheme's standard port (80 for ws, 443 for wss).
    let port: Int?
    /// Path plus query exactly as given, "/" if the URL had none.
    let path: String
    let useTLS: Bool

    /// Why a URL was refused. Reads as the end of a sentence about the URL ("must be ...").
    struct Invalid: LocalizedError {
        let reason: String
        var errorDescription: String? { "Invalid broker URL: it \(reason)" }
    }

    /// Strict: the URL must already be `ws://` or `wss://`.
    init(url: String) throws {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: trimmed),
              let scheme = parts.scheme?.lowercased(), scheme == "ws" || scheme == "wss",
              let host = parts.host, !host.isEmpty else {
            throw Invalid(reason: "must be a WebSocket URL like wss://example.duckdns.org/mqtt (starting with ws:// or wss://)")
        }
        if parts.user != nil || parts.password != nil {
            throw Invalid(reason: "must not contain a username or password; they have their own settings")
        }
        let path = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
        self.host = host
        self.port = parts.port
        self.path = parts.percentEncodedQuery.map { path + "?" + $0 } ?? path
        self.useTLS = scheme == "wss"
    }

    /// For typed input: makes sure the URL starts with `wss://`. A bare host gets the prefix and
    /// `ws://` is upgraded. Any other scheme is left alone, so `init(url:)` rejects it.
    static func normalized(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("wss://") { return trimmed }
        if lower.hasPrefix("ws://") { return "wss://" + trimmed.dropFirst(5) }
        if lower.contains("://") { return trimmed }
        return "wss://" + trimmed
    }
}

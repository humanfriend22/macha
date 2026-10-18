import Foundation

/// Logs to stderr. Under `brew services` / launchd this ends up in the service's log file.
enum Log {
    private static let formatter = ISO8601DateFormatter()

    static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

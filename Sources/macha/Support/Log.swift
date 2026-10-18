import Foundation

/// Logs to stderr. Under `brew services` / launchd this ends up in the service's log file.
enum Log {
    private static let formatter = ISO8601DateFormatter()
    private static let lock = NSLock()
    private static var limited: [String: (last: Date, skipped: Int)] = [:]

    static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// For messages that can repeat forever (a broker that stays down): logs the first one, then
    /// at most one per `interval` for the same `key`, noting how many were skipped in between.
    /// Use `.infinity` to log once until `reset(key)`.
    static func info(_ message: String, key: String, every interval: TimeInterval) {
        lock.lock()
        let state = limited[key]
        if let state, Date().timeIntervalSince(state.last) < interval {
            limited[key] = (state.last, state.skipped + 1)
            lock.unlock()
            return
        }
        limited[key] = (Date(), 0)
        lock.unlock()
        let skipped = state?.skipped ?? 0
        info(message + (skipped > 0 ? " (\(skipped) more since the last message)" : ""))
    }

    /// Forgets `key`, so its next message is logged at once. Returns how many were skipped.
    @discardableResult
    static func reset(key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return limited.removeValue(forKey: key)?.skipped ?? 0
    }
}

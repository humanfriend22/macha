import ArgumentParser
import Darwin
import Foundation

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the agent in the foreground (this is what brew services starts)."
    )

    func run() throws {
        let config = try Config.load()
        let manager = try ConnectionManager(config: config)

        // Start every source that provides at least one enabled sensor. The manager drops
        // sends for sensors that aren't enabled. Add new sources to `SensorSources.all`.
        let enabled = Set(config.enabledSensors)
        for id in enabled.subtracting(SensorSources.sensors.map(\.id)).sorted() {
            Log.info("ignoring unknown sensor `\(id)` (run `macha configure` to see the available ones)")
        }
        let sources: [any SensorSource] = SensorSources.all
            .filter { type in type.sensors.contains { enabled.contains($0.id) } }
            .map { $0.init(manager: manager) }

        // On SIGTERM (brew services stop) or Ctrl-C: stop sources, tell HA we're offline, exit.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let signalSources = [SIGTERM, SIGINT].map { sig -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                Log.info("shutting down")
                sources.forEach { $0.stop() }
                manager.shutdown()
                // Qualified: inside a ParsableCommand a bare exit() resolves to ArgumentParser's static exit(withError:).
                Darwin.exit(0)
            }
            source.resume()
            return source
        }

        Log.info("macha \(Macha.configuration.version) starting as \"\(config.username)\" (\(config.redactedDescription))")
        manager.start()

        // Each source starts in its own main-queue task, so one slow source doesn't hold up the others.
        // (IOBluetooth and similar APIs need the main thread and the main run loop.)
        for source in sources {
            DispatchQueue.main.async { source.start() }
        }

        withExtendedLifetime(signalSources) {
            RunLoop.main.run()
        }
    }
}

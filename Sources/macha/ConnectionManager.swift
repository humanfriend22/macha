import Foundation
import MQTTNIO
import NIOCore
import NIOPosix

/// Owns the one long-lived MQTT connection and everything around it. Sensor sources call `send`;
/// the Network source also reports network changes and sleep/wake (`networkChanged`, `willSleep`, `didWake`).
///
/// Built to run for weeks without attention:
///  - connects with a last-will, so Home Assistant marks the Mac unavailable if it vanishes
///  - reconnects forever with capped backoff, immediately when the network returns or the Mac wakes
///  - notices dead connections that never report closing (every publish and a 60s ping have a
///    10s timeout; a failure drops the connection and reconnects)
///  - never queues: while offline, `send` only remembers the NEWEST value per topic (memory is
///    bounded by the number of topics), and that current state is sent after reconnecting
///  - logs outages once an hour instead of on every retry, so log files stay small
///
/// Topic layout (keep in sync with the broker ACL):
///   macha/<node>/availability
///   macha/<node>/<id>/state
///   macha/<node>/<id>/attributes
///   <discovery_prefix>/<component>/macha_<node>/<id>/config
/// <node> is the MQTT username, so one ACL rule per kind of topic (using `%u`) limits every
/// user to its own topics.
final class ConnectionManager {
    let config: Config
    private let node: String
    private let availabilityTopic: String
    private let client: MQTTClient

    /// All mutable state below is only touched on this queue.
    private let queue = DispatchQueue(label: "macha.connection")
    private var sensors: [String: Sensor] = [:]   // by id, filled by the first `send` of each
    private var latest: [String: String] = [:]     // topic -> newest payload wanted
    private var sent: [String: String] = [:]       // topic -> payload published in this broker session
    private enum State { case disconnected, connecting, connected, stopped }
    private var state = State.disconnected
    private var isConnected: Bool { state == .connected }
    /// Reasons not to connect right now, besides `state`.
    private var networkAvailable = true
    private var sleeping = false
    /// Bumped whenever the connection comes up or goes down, so late callbacks from an old
    /// connection can be recognised and ignored.
    private var generation = 0
    private var retryDelay: Double = 1
    private var retryWork: DispatchWorkItem?
    private var healthTimer: DispatchSourceTimer?
    private var sweeping = false
    private var sweepMessages: [String: String] = [:]   // retained discovery messages seen while sweeping

    /// `clientID` is only for `macha doctor`, so it never kicks a running agent off the broker.
    init(config: Config, clientID: String? = nil) {
        let endpoint = config.endpoint
        let node = config.username
        self.config = config
        self.node = node
        self.availabilityTopic = "macha/\(node)/availability"
        self.client = MQTTClient(
            host: endpoint.host,
            port: endpoint.port,   // nil: the library uses the scheme's standard port (80 / 443)
            identifier: clientID ?? "macha-\(node)",
            eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton),
            configuration: .init(
                keepAliveInterval: .seconds(30),
                connectTimeout: .seconds(10),
                // Without this an unanswered ping or publish waits forever on a half-dead connection.
                timeout: .seconds(10),
                userName: config.username,
                password: config.password,
                useSSL: endpoint.useTLS,
                useWebSockets: true,
                webSocketURLPath: endpoint.path
            )
        )
        // The library doesn't reconnect by itself; this tells us when the connection closed.
        client.addCloseListener(named: "macha") { [weak self] _ in
            self?.queue.async { self?.connectionClosed() }
        }
        // Only used while sweeping for stale sensors (see sweepStaleSensors).
        client.addPublishListener(named: "macha-sweep") { [weak self] result in
            guard case .success(let info) = result, info.payload.readableBytes > 0 else { return }
            let text = String(buffer: info.payload)
            self?.queue.async {
                guard let self, self.sweeping else { return }
                self.sweepMessages[info.topicName] = text
            }
        }
    }

    // MARK: - Public API (thread-safe)

    /// Starts connecting. Call once, on the main thread.
    func start() {
        queue.async {
            self.startHealthTimer()
            self.connect()
        }
    }

    /// Reports a sensor's state (e.g. "ON", "OFF", "3", or nil if it has none) and optionally its attributes.
    /// Call it freely from any thread, as often as you like, connected or not:
    ///  - sensors that aren't in `enabled_sensors` are ignored
    ///  - unchanged values are skipped
    ///  - while offline nothing is queued; only the newest value is kept and sent on reconnect
    ///  - the first send of a sensor also announces it to Home Assistant (MQTT discovery)
    func send(_ state: String?, attributes: [String: Any]? = nil, for sensor: Sensor) {
        guard config.isEnabled(sensor) else { return }
        let attributesJSON = attributes.flatMap(ConnectionManager.json)
        queue.async {
            if self.sensors[sensor.id] == nil {
                self.sensors[sensor.id] = sensor
                if self.isConnected { self.publishDiscovery(sensor) }
            }
            if let state { self.deliver(self.stateTopic(sensor), state) }
            if let attributesJSON { self.deliver(self.attributesTopic(sensor), attributesJSON) }
        }
    }

    /// For `macha doctor`: connects once to the broker (no retries, no availability, no discovery),
    /// disconnects, and returns the error if it failed. Use a manager made with its own `clientID`.
    func probe(timeout seconds: Double = 10) -> Error? {
        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?
        client.connect().whenComplete { result in
            if case .failure(let error) = result { failure = error }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + seconds) == .timedOut {
            return ProbeError.noAnswer(seconds)
        }
        if failure == nil { wait(for: client.disconnect(), seconds: 2) }
        return failure
    }

    enum ProbeError: LocalizedError {
        case noAnswer(Double)
        var errorDescription: String? {
            switch self {
            case .noAnswer(let seconds): return "no answer within \(Int(seconds)) seconds"
            }
        }
    }

    /// Publishes "offline", disconnects and shuts the client down. Call from the main thread
    /// (not from an NIO event loop) right before exiting.
    func shutdown() {
        queue.sync {
            let wasConnected = isConnected
            state = .stopped
            retryWork?.cancel()
            retryWork = nil
            healthTimer?.cancel()
            healthTimer = nil
            if wasConnected {
                wait(for: publishRaw(availabilityTopic, "offline"), seconds: 2)
                wait(for: client.disconnect(), seconds: 1)
            }
        }
        // MQTTClient crashes if it is deallocated without being shut down.
        try? client.syncShutdownGracefully()
    }

    // MARK: - Connecting

    private func connect() {
        guard state == .disconnected, !sleeping, networkAvailable else { return }
        state = .connecting
        retryWork?.cancel()
        retryWork = nil

        // Broker publishes this for us if the connection dies without a clean disconnect.
        let will = (
            topicName: availabilityTopic,
            payload: ByteBuffer(string: "offline"),
            qos: MQTTQoS.atLeastOnce,
            retain: true
        )
        client.connect(will: will).whenComplete { [weak self] result in
            self?.queue.async { self?.connectFinished(result) }
        }
    }

    private func connectFinished(_ result: Result<Bool, Error>) {
        let stopped = state == .stopped
        if !stopped { state = .disconnected }
        switch result {
        case .success:
            guard !stopped else { return }
            state = .connected
            generation += 1
            retryDelay = 1
            let missed = Log.reset(key: "connect-failure")
            Log.info("connected to \(config.url)" + (missed > 0 ? " (\(missed) failed attempts not logged)" : ""))
            announce()
        case .failure(let error):
            Log.info("can't connect to \(config.url): \(error)", key: "connect-failure", every: 3600)
            scheduleReconnect()
        }
    }

    /// The library told us the connection closed (not called for connections we dropped ourselves).
    private func connectionClosed() {
        guard isConnected else { return }   // failed connect, sleep, shutdown or dropConnection already handled it
        state = .disconnected
        generation += 1
        Log.info("connection closed, reconnecting")
        scheduleReconnect()
    }

    /// Gives up on the current connection: used when a ping or publish gets no answer.
    private func dropConnection(_ reason: String) {
        guard isConnected else { return }
        Log.info("connection lost (\(reason)), reconnecting")
        state = .disconnected
        generation += 1
        client.disconnect().whenComplete { _ in }   // best effort: closes the socket
        retryDelay = 1
        scheduleReconnect()
    }

    /// Retry with exponential backoff (1s, 2s, 4s ... capped at 60s). Safe to call repeatedly.
    private func scheduleReconnect() {
        guard state != .stopped, !sleeping, retryWork == nil else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 60)
        let work = DispatchWorkItem { [weak self] in
            self?.retryWork = nil
            self?.connect()
        }
        retryWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The Network source reports whether the Mac has a route. Safe to call from any thread.
    func networkChanged(available: Bool) {
        queue.async { self.applyNetwork(available) }
    }

    private func applyNetwork(_ available: Bool) {
        networkAvailable = available
        if available {
            // Network is back: don't wait for the backoff timer.
            guard !isConnected else { return }
            retryDelay = 1
            retryWork?.cancel()
            retryWork = nil
            connect()
        } else {
            Log.info("network unavailable")
            retryWork?.cancel()
            retryWork = nil
            // The socket is dead even if the library hasn't noticed yet.
            if isConnected {
                state = .disconnected
                generation += 1
                client.disconnect().whenComplete { _ in }
            }
        }
    }

    // MARK: - Dead-connection detection

    /// A ping every minute with a 10s timeout. The library's own pings only report failures
    /// through the channel, so this makes sure a silently dead connection is always replaced.
    private func startHealthTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in self?.healthCheck() }
        timer.resume()
        healthTimer = timer
    }

    private func healthCheck() {
        guard isConnected else { return }
        let gen = generation
        client.ping().whenComplete { [weak self] result in
            guard case .failure(let error) = result else { return }
            self?.queue.async {
                guard let self, self.generation == gen else { return }
                self.dropConnection("ping failed: \(error)")
            }
        }
    }

    // MARK: - Sleep / wake (called by the Network source)

    /// Tell Home Assistant right away instead of waiting for the broker's keep-alive timeout.
    /// Runs on the main thread and blocks briefly, because the Mac is about to sleep.
    func willSleep() {
        queue.sync {
            sleeping = true
            retryWork?.cancel()
            retryWork = nil
            guard isConnected else { return }
            Log.info("going to sleep, disconnecting")
            wait(for: publishRaw(availabilityTopic, "offline"), seconds: 2)
            wait(for: client.disconnect(), seconds: 1)
            state = .disconnected
            generation += 1
        }
    }

    func didWake() {
        // Give Wi-Fi and DNS a moment; the network monitor also triggers a connect when ready.
        queue.asyncAfter(deadline: .now() + 2) {
            self.sleeping = false
            self.retryDelay = 1
            self.connect()
        }
    }

    // MARK: - Publishing

    /// After every (re)connect: availability, discovery for known sensors, then the newest state of everything.
    private func announce() {
        sent.removeAll()
        publishRaw(availabilityTopic, "online")
        for sensor in sensors.values { publishDiscovery(sensor) }
        sweepStaleSensors()
        for (topic, payload) in latest {
            sent[topic] = payload
            publishRaw(topic, payload)
        }
    }

    /// Records the wanted value, and publishes it if connected and it differs from what the broker has.
    /// When offline this is a no-op beyond remembering the value: nothing is queued.
    private func deliver(_ topic: String, _ payload: String) {
        latest[topic] = payload
        guard isConnected, sent[topic] != payload else { return }
        sent[topic] = payload
        publishRaw(topic, payload)
    }

    /// Publishes, and treats any failure as a sign the connection is bad.
    @discardableResult
    private func publishRaw(_ topic: String, _ payload: String) -> EventLoopFuture<Void> {
        let gen = generation
        let future = client.publish(to: topic, payload: ByteBuffer(string: payload), qos: .atLeastOnce, retain: true)
        future.whenFailure { [weak self] error in
            self?.queue.async {
                guard let self else { return }
                self.sent[topic] = nil   // allow a resend
                // Ignore failures from an older connection, and "no connection" which we already know about.
                guard self.generation == gen, self.isConnected else { return }
                self.dropConnection("publish failed: \(error)")
            }
        }
        return future
    }

    private func publishDiscovery(_ sensor: Sensor) {
        var payload: [String: Any] = [
            "name": sensor.name,
            "unique_id": "macha_\(node)_\(sensor.id)",
            "availability_topic": availabilityTopic,
            "device": [
                "identifiers": ["macha_\(node)"],
                "name": config.username,
                "manufacturer": "Apple",
                "model": "Mac",
            ],
        ]
        if sensor.hasState { payload["state_topic"] = stateTopic(sensor) }
        if sensor.hasAttributes { payload["json_attributes_topic"] = attributesTopic(sensor) }
        if let deviceClass = sensor.deviceClass { payload["device_class"] = deviceClass }
        if let unit = sensor.unit { payload["unit_of_measurement"] = unit }
        if let icon = sensor.icon { payload["icon"] = icon }
        if let stateClass = sensor.stateClass { payload["state_class"] = stateClass }

        guard let json = ConnectionManager.json(payload) else { return }
        publishRaw(discoveryTopic(sensor), json)
    }

    // MARK: - Removing stale sensors

    /// Asks the broker which discovery messages it still holds for this Mac (they are retained)
    /// and deletes the ones for sensors we don't want now: switched off in `macha configure`,
    /// or no longer in macha. An empty retained message on a discovery topic makes Home Assistant
    /// remove the entity; its state topics are cleared too.
    ///
    /// Needs read access to `<discovery_prefix>/<component>/macha_<node>/+/config` on the broker, for each
    /// component macha uses (`Sensor.Component`). Without it, this logs once and does nothing. Only this Mac's messages are touched: each is matched
    /// by the device identifier inside it, never by guessing from the topic name.
    private func sweepStaleSensors() {
        let gen = generation
        // One explicit filter per component, not a `+`, so the broker ACL can grant exactly these.
        let filters = Sensor.Component.allCases.map { "\(config.discoveryPrefix)/\($0.rawValue)/macha_\(node)/+/config" }
        sweepMessages.removeAll()
        sweeping = true
        client.subscribe(to: filters.map { MQTTSubscribeInfo(topicFilter: $0, qos: .atLeastOnce) }).whenComplete { [weak self] result in
            self?.queue.async {
                guard let self, self.generation == gen else { return }
                if case .success(let suback) = result, !suback.returnCodes.contains(.failure) {
                    // The broker sends the retained messages right after the SUBACK; give them a moment.
                    self.queue.asyncAfter(deadline: .now() + 2) {
                        guard self.generation == gen else { return }
                        self.finishSweep(filters: filters)
                    }
                } else {
                    self.sweeping = false
                    Log.info("can't list retained sensors on \(filters.joined(separator: ", ")) (no read access?); removed sensors won't be cleaned up",
                             key: "sweep-denied", every: .infinity)
                }
            }
        }
    }

    private func finishSweep(filters: [String]) {
        sweeping = false
        client.unsubscribe(from: filters).whenComplete { _ in }
        defer { sweepMessages.removeAll() }
        guard isConnected else { return }

        let wanted = Set(config.enabledSensors.map(\.id))
        let idPrefix = "macha_\(node)_"
        for (topic, text) in sweepMessages {
            guard let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  let device = json["device"] as? [String: Any],
                  (device["identifiers"] as? [String])?.contains("macha_\(node)") == true,
                  let uniqueID = json["unique_id"] as? String,
                  uniqueID.hasPrefix(idPrefix) else { continue }
            let id = String(uniqueID.dropFirst(idPrefix.count))
            guard !wanted.contains(id) else { continue }

            Log.info("removing sensor `\(id)` from Home Assistant")
            publishRaw(topic, "")   // discovery first, so HA drops the entity before the state vanishes
            for key in ["state_topic", "json_attributes_topic"] {
                if let stateTopic = json[key] as? String { publishRaw(stateTopic, "") }
            }
        }
    }

    // MARK: - Helpers

    private func discoveryTopic(_ sensor: Sensor) -> String {
        "\(config.discoveryPrefix)/\(sensor.component.rawValue)/macha_\(node)/\(sensor.id)/config"
    }
    private func stateTopic(_ sensor: Sensor) -> String { "macha/\(node)/\(sensor.id)/state" }
    private func attributesTopic(_ sensor: Sensor) -> String { "macha/\(node)/\(sensor.id)/attributes" }

    private static func json(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Blocks until the future completes or the timeout passes. Never call on an NIO event loop.
    private func wait<T>(for future: EventLoopFuture<T>, seconds: Double) {
        let semaphore = DispatchSemaphore(value: 0)
        future.whenComplete { _ in semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + seconds)
    }
}

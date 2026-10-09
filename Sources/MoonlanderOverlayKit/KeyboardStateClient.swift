import Darwin
import Foundation

/// Connection state reported by the `moonlander-keyboard-state` helper.
nonisolated public enum KeyboardConnectionState: String, Codable, Sendable {
    /// The helper owns the raw HID interface and reports layer and held keys.
    case connected
    /// Another process (normally Keymapp) holds the raw HID interface.
    case busy
    /// No Moonlander is reachable over USB.
    case disconnected
    /// The keyboard is present but the Oryx handshake did not succeed.
    case unavailable
}

/// One key position in the Moonlander's QMK matrix, as reported by the helper.
///
/// Only the board's 72 verified positions can exist, so a report naming a nonexistent
/// key cannot turn into a held-key highlight.
nonisolated public struct MatrixPosition: Codable, Sendable, Hashable {
    public let row: Int
    public let column: Int

    /// Creates a position, or returns `nil` when the pair is not one of the board's keys.
    public init?(row: Int, column: Int) {
        guard MoonlanderMatrix.oryxIndex(forRow: row, column: column) != nil else { return nil }
        self.row = row
        self.column = column
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let row = try container.decode(Int.self, forKey: .row)
        let column = try container.decode(Int.self, forKey: .column)
        guard MoonlanderMatrix.oryxIndex(forRow: row, column: column) != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .column,
                in: container,
                debugDescription: "row \(row) column \(column) is not a Moonlander matrix position"
            )
        }
        self.row = row
        self.column = column
    }

    private enum CodingKeys: String, CodingKey {
        case row
        case column
    }
}

/// One complete newline-delimited JSON snapshot emitted by the helper.
///
/// A snapshot is the whole picture — state, layer and the keys held right now — so the
/// client never replays an event journal: a changed key or layer arrives immediately and
/// the same picture repeats on the heartbeat. `message` and `keyboard` are decorative and
/// default when the helper omits them.
///
/// Decoding enforces the invariants the overlay relies on:
/// * `.connected` requires a byte-sized `layer` (`0..<256`) and the `pressed` array, so a
///   broken or truncated report can never fabricate a layer or a key release.
/// * every `pressed` position must be a verified Moonlander key; one bad position
///   invalidates the whole record rather than dropping a key silently.
/// * any other state is normalized to `layer == nil` and `pressed == []` whatever the
///   payload says, because layer and held keys only mean something on a connected board —
///   a busy, disconnected or unavailable snapshot always clears the display.
nonisolated public struct KeyboardStateMessage: Codable, Sendable, Equatable {
    public let state: KeyboardConnectionState
    /// Current layer (`0..<256`); set only while `.connected`.
    public let layer: Int?
    /// Matrix positions held right now; empty unless `.connected`.
    public let pressed: [MatrixPosition]
    /// Human-readable status text from the helper, `""` when there is nothing to say.
    public let message: String
    /// Keyboard name reported by the helper, when it knows one.
    public let keyboard: String?

    /// The held keys as Oryx key ids, matching `PhysicalKey.id` in the bundled keymap.
    public var pressedKeyIDs: Set<Int> {
        Set(pressed.compactMap { MoonlanderMatrix.oryxIndex(forRow: $0.row, column: $0.column) })
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(KeyboardConnectionState.self, forKey: .state)

        self.state = state
        self.message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        self.keyboard = try container.decodeIfPresent(String.self, forKey: .keyboard)

        switch state {
        case .connected:
            let layer = try container.decode(Int.self, forKey: .layer)
            guard (0..<256).contains(layer) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .layer,
                    in: container,
                    debugDescription: "layer \(layer) is outside 0..<256"
                )
            }
            self.layer = layer
            // Required, never defaulted: a snapshot that omits its held keys would
            // otherwise read as "nothing held" and fabricate a key release.
            self.pressed = try container.decode([MatrixPosition].self, forKey: .pressed)
        case .busy, .disconnected, .unavailable:
            self.layer = nil
            self.pressed = []
        }
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case layer
        case pressed
        case message
        case keyboard
    }
}

/// Splits the helper's stdout byte stream into complete snapshots.
///
/// Handles several records per read and records split across reads — including in the
/// middle of a multibyte character — plus CRLF, blank lines and malformed input: a bad
/// record is skipped instead of poisoning the rest of the stream. Buffered bytes are
/// bounded, so an unterminated line cannot grow memory without limit.
nonisolated public struct KeyboardStateParser: Sendable {
    /// A snapshot decodes to a few hundred bytes; anything still unterminated after this
    /// much input is malformed and gets dropped to resynchronize.
    private static let maximumBufferedBytes = 64 * 1024

    private var buffer = Data()

    public init() {}

    /// Discards any partial record. The client calls this whenever the helper starts, so
    /// a truncated line from a dead helper cannot merge into the new stream.
    public mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
    }

    /// Appends one read and returns every snapshot that is now complete, in order.
    public mutating func consume(_ chunk: Data) -> [KeyboardStateMessage] {
        buffer.append(chunk)
        var messages: [KeyboardStateMessage] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if let message = Self.parse(line: line) {
                messages.append(message)
            }
        }
        if buffer.count > Self.maximumBufferedBytes {
            reset()
        }
        return messages
    }

    /// Decodes one complete NDJSON record; `nil` for blank, malformed or inconsistent
    /// records (unknown state, missing or non-byte layer while connected, unknown matrix
    /// position, wrong field types).
    public static func parse(line: Data) -> KeyboardStateMessage? {
        let trimmed = line.drop { $0 == 0x0D || $0 == 0x20 || $0 == 0x09 }
        guard !trimmed.isEmpty else { return nil }
        return try? JSONDecoder().decode(KeyboardStateMessage.self, from: Data(trimmed))
    }
}

/// Buffers raw stdout from the helper's readability callbacks until the main actor
/// drains it, preserving arrival order across callbacks. The lock guards every access,
/// including the ones from the pipe's callback queue.
nonisolated private final class HelperOutputQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        chunks.append(chunk)
    }

    func drain() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        let pending = chunks
        chunks.removeAll(keepingCapacity: true)
        return pending
    }
}

/// Owns the bundled `moonlander-keyboard-state` helper and turns its stdout into
/// availability updates.
///
/// The helper prints whole snapshots only, so `.live` always carries the current
/// picture; there is no event journal to replay and no timestamp to infer. Staleness is
/// detected here, so a dead or hung helper degrades to `.stale` instead of leaving a
/// frozen layer or key highlight on screen.
///
/// Lifecycle guarantees:
/// * `start()` is idempotent while a helper runs; `stop()` terminates it and marks
///   `.stopped`; `restartNow()` is `stop()` followed by `start()`.
/// * Every helper run gets a fresh session and a fresh parser; output and exit callbacks
///   from an older process can never mutate a newer one.
/// * Only one helper runs at a time: when a released helper is still exiting, its
///   replacement waits for the exit — escalating to SIGKILL of that child after a grace
///   period — so two helpers never hold the raw HID interface at once.
/// * Callbacks are delivered on the main actor, in stream order.
@MainActor
public final class KeyboardStateClient {
    nonisolated public enum Availability: Sendable, Equatable {
        case starting
        case live(KeyboardStateMessage)
        case stale
        case stopped
    }

    public private(set) var availability: Availability = .stopped
    public var onUpdate: ((Availability) -> Void)?

    /// How long the helper has to report before the display goes stale — the same budget
    /// applies to the first snapshot and to the gap between heartbeats.
    private static let reportTimeout = Duration.milliseconds(1500)
    private static let watchdogInterval = Duration.milliseconds(250)
    private static let maximumRestartDelay = Duration.seconds(5)

    private let clock = ContinuousClock()
    private let sidecarURL: URL
    private let intervalMilliseconds: Int
    private var process: Process?
    private var outPipe: Pipe?
    private var errPipe: Pipe?
    private var outputQueue: HelperOutputQueue?
    private var parser = KeyboardStateParser()
    private var lastMessageAt: ContinuousClock.Instant?
    private var startedAt: ContinuousClock.Instant?
    private var staleTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var restartDelay = Duration.milliseconds(400)
    private var stopping = true
    /// A terminated helper that has not been reaped yet; the next `start()` waits for it
    /// to exit so two helpers never hold the raw HID interface at the same time.
    private var exitingProcess: Process?
    private var startPending = false
    private var pendingExitTask: Task<Void, Never>?
    /// Bumped whenever a helper is released; callbacks carrying an older value belong to
    /// a previous process and must not touch the current one.
    private var session = 0

    public init(sidecarURL: URL, intervalMilliseconds: Int = 200) {
        self.sidecarURL = sidecarURL
        self.intervalMilliseconds = intervalMilliseconds
    }

    /// Resolves the helper: environment override first (development), then the app bundle.
    public static func resolveSidecarURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> URL? {
        if let override = environment["MOONLANDER_SIDECAR"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        let bundled = bundle.bundleURL.appending(path: "Contents/Helpers/moonlander-keyboard-state")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        return nil
    }

    public func start() {
        guard process == nil else { return }
        stopping = false
        staleTask?.cancel()
        staleTask = nil
        restartTask?.cancel()
        restartTask = nil
        restartDelay = Duration.milliseconds(400)
        if let exitingProcess, exitingProcess.isRunning {
            startPending = true
            if pendingExitTask == nil { scheduleExitEscalation() }
        } else {
            clearExitingProcess()
            spawn()
        }
    }

    public func stop() {
        stopping = true
        startPending = false
        staleTask?.cancel()
        staleTask = nil
        restartTask?.cancel()
        restartTask = nil
        releaseProcess()
        setAvailability(.stopped)
    }

    public func restartNow() {
        stop()
        start()
    }

    // MARK: - Process lifecycle

    private func spawn() {
        // A running helper always implies no start is still waiting for an older one.
        startPending = false

        let outPipe = Pipe()
        let errPipe = Pipe()
        let process = Process()
        process.executableURL = sidecarURL
        process.arguments = ["--watch", "--interval-ms", String(intervalMilliseconds)]
        process.standardOutput = outPipe
        process.standardError = errPipe

        let session = self.session
        let outputQueue = HelperOutputQueue()

        process.terminationHandler = { [weak self] finished in
            let identity = ObjectIdentifier(finished)
            let status = finished.terminationStatus
            Task { @MainActor in self?.handleExit(identity: identity, session: session, status: status) }
        }
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            outputQueue.append(chunk)
            Task { @MainActor in self?.drainOutput(outputQueue) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            FileHandle.standardError.write(chunk) // helper diagnostics stay on stderr
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            indicatorFallback("cannot start keyboard state helper: \(error.localizedDescription)")
            scheduleRestart()
            return
        }

        self.process = process
        self.outPipe = outPipe
        self.errPipe = errPipe
        self.outputQueue = outputQueue
        parser.reset()
        lastMessageAt = nil
        startedAt = clock.now
        setAvailability(.starting)
        startStaleWatchdog()
    }

    /// Ends the current session: no queued callback from this process can touch state
    /// afterwards. The helper is terminated but not waited on, so the main actor never
    /// blocks.
    private func releaseProcess() {
        session &+= 1
        outPipe?.fileHandleForReading.readabilityHandler = nil
        errPipe?.fileHandleForReading.readabilityHandler = nil
        if let process {
            if process.isRunning {
                process.terminate()
                exitingProcess = process // tracked until its exit has been observed
                scheduleExitEscalation()
            } else {
                clearExitingProcess()
            }
        } else if let exitingProcess, !exitingProcess.isRunning {
            // No current helper: forget a tracked one only once it is observed gone.
            clearExitingProcess()
        }
        process = nil
        outPipe = nil
        errPipe = nil
        outputQueue = nil
        lastMessageAt = nil
        startedAt = nil
        // The pipes are released, not closed explicitly: a readability callback already
        // in flight still holds its FileHandle, and `availableData` on a closed handle
        // aborts the process. ARC closes the descriptor once that callback returns.
    }

    private func handleExit(identity: ObjectIdentifier, session: Int, status: Int32) {
        if let exitingProcess, ObjectIdentifier(exitingProcess) == identity {
            clearExitingProcess()
            spawnIfStartPending()
            return
        }
        guard session == self.session else { return }
        releaseProcess()
        guard !stopping else { return }
        indicatorFallback("keyboard state helper exited (\(status)) — retrying")
        scheduleRestart()
    }

    /// Spawns the replacement a `start()` asked for, now that the previous helper is gone.
    private func spawnIfStartPending() {
        guard startPending, !stopping, process == nil, exitingProcess == nil else { return }
        startPending = false
        spawn()
    }

    /// Forgets the tracked helper once its exit has been observed.
    private func clearExitingProcess() {
        pendingExitTask?.cancel()
        pendingExitTask = nil
        exitingProcess = nil
    }

    /// Waits for a released helper to exit, killing that child after the grace period if
    /// it has not: a stopped helper (SIGSTOP during diagnostics, say) never notices
    /// SIGTERM, and it must neither hold the raw HID interface nor become an orphan. Only
    /// the tracked child is ever signalled, and the main actor never blocks.
    private func scheduleExitEscalation() {
        pendingExitTask?.cancel()
        pendingExitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, let self, let exiting = self.exitingProcess else { return }
            if exiting.isRunning {
                kill(exiting.processIdentifier, SIGKILL) // SIGKILL is not catchable, so this settles it
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else { return }
            self.clearExitingProcess()
            self.spawnIfStartPending()
        }
    }

    private func scheduleRestart() {
        restartTask?.cancel()
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, Self.maximumRestartDelay)
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.stopping, self.process == nil else { return }
            self.spawn()
        }
    }

    // MARK: - Stream handling

    /// Applies every byte a session's callbacks have buffered, in the order it arrived.
    /// A queue left behind by a released helper is ignored, so old reads never touch
    /// newer state.
    private func drainOutput(_ queue: HelperOutputQueue) {
        guard outputQueue === queue else { return }
        for chunk in queue.drain() {
            ingest(chunk)
        }
    }

    private func ingest(_ chunk: Data) {
        for message in parser.consume(chunk) {
            lastMessageAt = clock.now
            restartDelay = Duration.milliseconds(400)
            let next = Availability.live(message)
            if availability != next { setAvailability(next) }
        }
    }

    private func startStaleWatchdog() {
        staleTask?.cancel()
        staleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.watchdogInterval)
                guard !Task.isCancelled, let self else { return }
                self.checkStale()
            }
        }
    }

    private func checkStale() {
        guard process != nil, !stopping else { return }
        let now = clock.now
        switch availability {
        case .starting:
            // Startup can hang just as quietly as a live stream, so it gets the same
            // explicit deadline instead of waiting forever for a first snapshot.
            if let startedAt, now - startedAt > Self.reportTimeout {
                setAvailability(.stale)
            }
        case .live:
            if let lastMessageAt, now - lastMessageAt > Self.reportTimeout {
                setAvailability(.stale)
            }
        case .stale, .stopped:
            break
        }
    }

    private func indicatorFallback(_ text: String) {
        setAvailability(.stale)
        FileHandle.standardError.write(Data("\(text)\n".utf8))
    }

    private func setAvailability(_ next: Availability) {
        availability = next
        onUpdate?(next)
    }
}

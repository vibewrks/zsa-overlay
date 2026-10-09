import Foundation

public enum LayerStatusState: String, Codable, Sendable {
    case connected
    case disconnected
    case unavailable
}

/// One newline-delimited JSON status record emitted by the Rust sidecar.
public struct LayerStatusMessage: Codable, Sendable, Equatable {
    public let state: LayerStatusState
    public let layer: Int?
    public let message: String
    public let keyboard: String?
}

/// Splits a byte stream into status messages. Handles partial lines, several messages per
/// chunk, CRLF, and skips blank or malformed lines instead of failing the whole stream.
public struct StatusLineParser: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func consume(_ chunk: Data) -> [LayerStatusMessage] {
        buffer.append(chunk)
        var messages: [LayerStatusMessage] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if let message = Self.parse(line: line) {
                messages.append(message)
            }
        }
        return messages
    }

    public static func parse(line: Data) -> LayerStatusMessage? {
        let trimmed = line.drop { $0 == 0x0D || $0 == 0x20 || $0 == 0x09 }
        guard !trimmed.isEmpty else { return nil }
        return try? JSONDecoder().decode(LayerStatusMessage.self, from: Data(trimmed))
    }
}

/// Owns the bundled sidecar process and turns its stdout into availability updates.
/// The sidecar reports on every poll; staleness is detected here so a dead or hung
/// helper degrades to an explicit indicator instead of a frozen layer display.
@MainActor
public final class LayerStatusClient {
    public enum Availability: Sendable, Equatable {
        case starting
        case live(LayerStatusMessage)
        case stale
        case stopped
    }

    public private(set) var availability: Availability = .stopped
    public var onUpdate: ((Availability) -> Void)?

    private let sidecarURL: URL
    private let intervalMilliseconds: Int
    private var process: Process?
    private var outPipe: Pipe?
    private var errPipe: Pipe?
    private var parser = StatusLineParser()
    private var lastMessageAt: Date?
    private var staleTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var restartDelay = Duration.milliseconds(400)
    private var stopping = true

    public init(sidecarURL: URL, intervalMilliseconds: Int = 100) {
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
        let bundled = bundle.bundleURL.appending(path: "Contents/Helpers/moonlander-layer-status")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        return nil
    }

    public func start() {
        guard process == nil else { return }
        stopping = false
        staleTask?.cancel()
        staleTask = nil
        restartDelay = .milliseconds(400)
        spawn()
    }

    public func stop() {
        stopping = true
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
        releaseProcess()

        let process = Process()
        process.executableURL = sidecarURL
        process.arguments = ["--watch", "--interval-ms", String(intervalMilliseconds)]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in self?.processExited(status: status) }
        }

        do {
            try process.run()
        } catch {
            indicatorFallback("cannot start helper: \(error.localizedDescription)")
            scheduleRestart()
            return
        }

        self.process = process
        self.outPipe = outPipe
        self.errPipe = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor in self?.ingest(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            FileHandle.standardError.write(data) // helper diagnostics stay on stderr
        }

        setAvailability(.starting)
        startStaleWatchdog()
    }

    private func releaseProcess() {
        outPipe?.fileHandleForReading.readabilityHandler = nil
        errPipe?.fileHandleForReading.readabilityHandler = nil
        if let process {
            process.terminationHandler = nil
            if process.isRunning { process.terminate() }
        }
        process = nil
        outPipe = nil
        errPipe = nil
        lastMessageAt = nil
    }

    private func processExited(status: Int32) {
        releaseProcess()
        guard !stopping else {
            setAvailability(.stopped)
            return
        }
        indicatorFallback("helper exited (\(status)) — retrying")
        scheduleRestart()
    }

    private func scheduleRestart() {
        restartTask?.cancel()
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, .seconds(5))
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.stopping, self.process == nil else { return }
            self.spawn()
        }
    }

    // MARK: - Stream handling

    private func ingest(_ data: Data) {
        for message in parser.consume(data) {
            lastMessageAt = Date()
            restartDelay = .milliseconds(400)
            let next = Availability.live(message)
            if availability != next { setAvailability(next) }
        }
    }

    private func startStaleWatchdog() {
        staleTask?.cancel()
        staleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                self.checkStale()
            }
        }
    }

    private func checkStale() {
        guard case .live = availability, let lastMessageAt else { return }
        if Date().timeIntervalSince(lastMessageAt) > 1.5 {
            setAvailability(.stale)
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

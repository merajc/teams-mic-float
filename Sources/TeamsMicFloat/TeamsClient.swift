import Foundation

@MainActor
final class TeamsClient {
    struct Options {
        var host = "127.0.0.1"
        var port = 8124
        var manufacturer = "TeamsMicFloat"
        var device = "FloatingButton"
        var app = "Teams Mic Float"
        var appVersion = "1.0.0"
        var autoPairOverride: Bool?
        var reconnectDelays: [TimeInterval] = [3, 4, 5]
        var pairingDelay: TimeInterval = 1
        var pairingRetry: TimeInterval = 20
        var heartbeatInterval: TimeInterval = 20
        var openTimeout: TimeInterval = 5
    }

    enum RequestKind {
        case toggle
        case pair
        case query
    }

    private struct PendingRequest {
        let action: String
        let kind: RequestKind
        let sentAt: Date
    }

    var onState: ((ClientState) -> Void)?
    var onNotice: ((Notice) -> Void)?

    private(set) var state = ClientState(detail: "Starting")
    private let config: ConfigStore
    private let options: Options
    private let autoPair: Bool

    private var token: String?
    private var pairedThisSession = false
    private var pairedAt: Date?
    private var failureCount = 0
    private var stopping = false
    private var reconnectRequested = false
    private var currentGeneration = 0
    private var isSocketOpen = false

    private var runTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var pairTask: Task<Void, Never>?
    private var queryTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var openTimeoutTask: Task<Void, Never>?

    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var socketDelegate: SocketDelegate?
    private var pending: [Int: PendingRequest] = [:]
    private var nextRequestId = 0

    init(config: ConfigStore, options: Options) {
        self.config = config
        self.options = options
        self.autoPair = options.autoPairOverride ?? config.autoPair
        self.token = config.token
        self.state.paired = token != nil
    }

    var endpoint: String { "ws://\(options.host):\(options.port)" }

    // MARK: - Lifecycle

    func start() {
        guard runTask == nil else { return }
        stopping = false
        runTask = Task { [weak self] in
            await self?.connectionLoop()
        }
    }

    func stop() async {
        stopping = true
        retryTask?.cancel()
        pairTask?.cancel()
        queryTask?.cancel()
        closeCurrentConnection()
        if let runTask {
            runTask.cancel()
            await runTask.value
        }
        runTask = nil
        updateState {
            $0.phase = .disconnected
            $0.connected = false
            $0.inMeeting = false
            $0.muted = false
            $0.muteKnown = false
            $0.canToggleMute = false
            $0.canPair = false
            $0.pairingRequired = false
            $0.detail = "Stopped"
            $0.retryIn = nil
        }
    }

    private func connectionLoop() async {
        failureCount = 0
        while !stopping && !Task.isCancelled {
            let immediate = reconnectRequested
            reconnectRequested = false
            await connectOnce()

            if stopping || Task.isCancelled { break }

            let delay: TimeInterval
            if immediate || reconnectRequested {
                reconnectRequested = false
                failureCount = 0
                delay = 0
            } else {
                delay = nextReconnectDelay()
            }

            if delay > 0 {
                updateState {
                    $0.retryIn = Int(delay.rounded())
                }
                let task: Task<Void, Never> = Task {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    return ()
                }
                retryTask = task
                await task.value
                retryTask = nil
            }
        }
        updateState {
            $0.phase = .disconnected
            $0.connected = false
            $0.inMeeting = false
            $0.muted = false
            $0.muteKnown = false
            $0.canToggleMute = false
            $0.canPair = false
            $0.pairingRequired = false
            $0.detail = "Stopped"
            $0.retryIn = nil
        }
        runTask = nil
    }

    private func connectOnce() async {
        queryTask?.cancel()
        updateState {
            $0.phase = .connecting
            $0.connected = false
            $0.paired = self.token != nil
            $0.inMeeting = false
            $0.muted = false
            $0.muteKnown = false
            $0.canToggleMute = false
            $0.canPair = false
            $0.pairingRequired = false
            $0.detail = "Connecting to Teams…"
            $0.lastError = nil
            $0.retryIn = nil
        }

        guard
            let url = TeamsProtocol.buildURL(
                host: options.host,
                port: options.port,
                token: token,
                manufacturer: options.manufacturer,
                device: options.device,
                app: options.app,
                appVersion: options.appVersion
            )
        else {
            updateDisconnected(
                message: "Invalid Teams endpoint",
                error: TeamsClientError.invalidEndpoint
            )
            failureCount += 1
            return
        }

        currentGeneration += 1
        let generation = currentGeneration
        pairedThisSession = false
        pairedAt = nil
        isSocketOpen = false
        pending.removeAll()

        let delegate = SocketDelegate(client: self, generation: generation)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: .main
        )
        let socket = session.webSocketTask(with: url)

        self.socketDelegate = delegate
        self.session = session
        self.socket = socket
        Log.info("Connecting to Teams at \(endpoint)")
        socket.resume()

        openTimeoutTask?.cancel()
        openTimeoutTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(
                nanoseconds: UInt64(self.options.openTimeout * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            self.openTimedOut(generation: generation)
        }

        do {
            try await receiveLoop(socket, generation: generation)
            if !stopping {
                updateDisconnected(message: "Disconnected from Teams", error: nil)
            }
        } catch is CancellationError {
            // Expected during reconnect or shutdown.
        } catch {
            updateDisconnected(message: describe(error), error: error)
            failureCount += 1
        }

        closeCurrentConnection()
    }

    private func receiveLoop(
        _ socket: URLSessionWebSocketTask,
        generation: Int
    ) async throws {
        while !Task.isCancelled {
            let message = try await socket.receive()
            if !isSocketOpen {
                socketDidOpen(generation: generation)
            }
            switch message {
            case .string(let text):
                handleFrame(text)
            case .data(let data):
                if let text = String(data: data, encoding: .utf8) {
                    handleFrame(text)
                } else {
                    Log.warn("Ignoring a non-UTF-8 Teams frame")
                }
            @unknown default:
                Log.warn("Ignoring an unknown WebSocket message type")
            }
        }
    }

    private func closeCurrentConnection() {
        currentGeneration += 1
        isSocketOpen = false
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        queryTask?.cancel()
        queryTask = nil
        pairTask?.cancel()
        pairTask = nil
        pending.removeAll()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        socketDelegate = nil
    }

    fileprivate func socketDidOpen(generation: Int) {
        guard generation == currentGeneration, !isSocketOpen else { return }
        isSocketOpen = true
        failureCount = 0
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        Log.info("WebSocket connected (protocol-version=\(TeamsProtocol.version))")
        updateState {
            $0.phase = .connected
            $0.connected = true
            $0.paired = self.token != nil
            $0.pairingRequired = false
            $0.inMeeting = false
            $0.muted = false
            $0.muteKnown = false
            $0.canToggleMute = false
            $0.canPair = false
            $0.detail = "Connected — waiting for Teams state"
            $0.lastError = nil
            $0.retryIn = nil
        }
        queryStateSoon(delay: 0.15)
        startHeartbeat(generation: generation)
    }

    fileprivate func socketDidClose(generation: Int) {
        guard generation == currentGeneration else { return }
        isSocketOpen = false
        session?.invalidateAndCancel()
    }

    private func openTimedOut(generation: Int) {
        guard generation == currentGeneration, !isSocketOpen else { return }
        Log.warn("Timed out waiting for the Teams WebSocket handshake")
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    private func updateDisconnected(message: String, error: Error?) {
        updateState {
            $0.phase = .disconnected
            $0.connected = false
            $0.paired = self.token != nil
            $0.pairingRequired = false
            $0.inMeeting = false
            $0.muted = false
            $0.muteKnown = false
            $0.canToggleMute = false
            $0.canPair = false
            $0.detail = message
            $0.lastError = message
        }
    }

    // MARK: - Incoming messages

    private func handleFrame(_ text: String) {
        let message: ServerMessage
        do {
            message = try TeamsProtocol.parse(text)
        } catch {
            Log.warn("Ignoring malformed Teams frame: \(error.localizedDescription)")
            return
        }

        if let refresh = message.tokenRefresh {
            acceptToken(refresh)
        }
        if let patch = message.meeting {
            applyMeetingPatch(patch)
        }
        if let requestId = message.requestId,
           message.response != nil || message.error != nil {
            handleServiceResponse(message, requestId: requestId)
        }
    }

    private func acceptToken(_ rawToken: String) {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validToken(token) else {
            Log.warn("Teams sent an unusable tokenRefresh value; ignoring it")
            return
        }
        self.token = token
        pairedThisSession = true
        pairedAt = Date()
        failureCount = 0
        pairTask?.cancel()
        pairTask = nil

        var saved = true
        do {
            try config.setToken(token)
        } catch {
            saved = false
            Log.error("Paired with Teams but could not save the token: \(error.localizedDescription)")
        }

        updateState {
            $0.paired = true
            $0.pairingRequired = false
            $0.canPair = false
            $0.detail = saved ? "Paired with Teams — token saved" : "Paired — token could not be saved"
        }
        Log.info(saved ? "Teams pairing token saved" : "Teams pairing token not saved")
        onNotice?(
            Notice(
                title: saved ? "Paired with Teams" : "Paired, but token not saved",
                message: saved
                    ? "Approval received. The pairing token is stored privately for future launches."
                    : "Teams approved the app, but config.json could not be written. You may need to pair again.",
                level: saved ? .success : .warning
            )
        )
        queryStateSoon(delay: 0.25)
    }

    private func applyMeetingPatch(_ patch: MeetingPatch) {
        var next = state
        if let muted = patch.isMuted {
            next.muted = muted
            next.muteKnown = true
        }
        if let inMeeting = patch.isInMeeting {
            next.inMeeting = inMeeting
        }
        if let canToggle = patch.canToggleMute {
            next.canToggleMute = canToggle
        }
        if let canPair = patch.canPair {
            let stalePairingFrame =
                canPair
                && pairedThisSession
                && (pairedAt.map { Date().timeIntervalSince($0) < 5 } ?? false)
            if !stalePairingFrame {
                next.canPair = canPair
                next.pairingRequired = canPair
                if canPair {
                    next.inMeeting = true
                } else if pairedThisSession || token != nil {
                    next.paired = true
                }
            }
        }
        if !next.inMeeting {
            next.canToggleMute = false
        }
        next.detail = detailText(for: next)
        setState(next)

        if state.canPair && autoPair && pairTask == nil {
            startPairLoop(force: false)
        }
    }

    private func detailText(for state: ClientState) -> String {
        if state.pairingRequired {
            return "Pairing required — approve the request in Teams"
        }
        if state.inMeeting {
            if !state.muteKnown {
                return "In call — syncing state"
            }
            return state.muted ? "In call — muted" : "In call — unmuted"
        }
        return "Connected — not in a call"
    }

    private func handleServiceResponse(_ message: ServerMessage, requestId: Int) {
        let pendingRequest = pending.removeValue(forKey: requestId)
        let kind = pendingRequest?.kind
        let error = (message.error ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let response = (message.response ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if !error.isEmpty {
            Log.info("Teams service error (\(String(describing: kind))): \(error)")
            if error.localizedCaseInsensitiveContains("no active call") {
                updateState {
                    $0.inMeeting = false
                    $0.canToggleMute = false
                    $0.detail = "Not in a call"
                }
                if kind == .toggle {
                    notify("Not in a call", "Teams reported no active call.", .info)
                }
            } else if kind == .pair {
                updateState {
                    $0.pairingRequired = true
                    $0.detail = "Pairing pending — approve the request in Teams"
                }
                notify(
                    "Pairing pending",
                    "Teams did not confirm pairing. Look for the Allow prompt in Teams. If it is not visible, open Teams → Settings → Privacy → Third-party app API.",
                    .warning
                )
            } else if kind == .toggle {
                notify("Teams could not change mute", String(error.prefix(220)), .warning)
            }
            return
        }

        if response.lowercased() == "success" {
            if kind == .toggle {
                updateState { $0.detail = "Mute changed — syncing with Teams" }
                queryStateSoon(delay: 0.2)
            }
            return
        }

        if response.localizedCaseInsensitiveContains("pairing") {
            Log.info("Pairing response: \(response)")
            updateState {
                $0.pairingRequired = true
                $0.detail = "Pairing pending — approve the request in Teams"
            }
        }
    }

    // MARK: - Commands

    func requestPrimaryAction() {
        Task { [weak self] in
            await self?.primaryAction()
        }
    }

    func primaryAction() async {
        if state.phase == .connecting {
            notify("Connecting", "Waiting for Teams to accept the connection.", .info)
            return
        }
        if !state.connected {
            notify(
                "Teams unavailable",
                "Retrying the Teams connection now. Make sure Teams is running and the third-party app API is enabled.",
                .warning
            )
            reconnect()
            return
        }
        if state.pairingRequired {
            triggerPairing(force: true)
            return
        }
        if state.canToggle {
            _ = await toggleMute()
            return
        }
        if state.inMeeting {
            notify(
                "Mute unavailable",
                "Teams is in a call but has not granted mute control yet. Approve the pairing request in Teams if one is showing.",
                .warning
            )
            return
        }
        notify("Not in a call", "Join a Teams call to enable the microphone button.", .info)
    }

    @discardableResult
    func toggleMute() async -> Bool {
        guard state.canToggle else { return false }
        do {
            _ = try await sendAction("toggle-mute", parameters: [:], kind: .toggle)
            updateState { $0.detail = "Mute command sent to Teams" }
            return true
        } catch {
            notify("Could not reach Teams", describe(error), .warning)
            return false
        }
    }

    func reconnect() {
        guard !stopping else { return }
        reconnectRequested = true
        retryTask?.cancel()
        retryTask = nil
        if socket == nil {
            if runTask == nil { start() }
            return
        }
        Log.info("Reconnect requested")
        updateDisconnected(message: "Reconnecting to Teams…", error: nil)
        closeCurrentConnection()
    }

    func forgetPairing() async {
        token = nil
        pairedThisSession = false
        pairedAt = nil
        do {
            try config.clearToken()
        } catch {
            Log.error("Could not clear the saved token: \(error.localizedDescription)")
        }
        updateState {
            $0.paired = false
            $0.pairingRequired = false
            $0.canPair = false
            $0.detail = "Pairing token cleared — reconnecting"
        }
        notify(
            "Pairing token cleared",
            "Reconnect and choose Allow when Teams shows the pairing prompt.",
            .info
        )
        reconnectRequested = true
        closeCurrentConnection()
        if runTask == nil { start() }
    }

    func triggerPairing(force: Bool) {
        if !force && !autoPair { return }
        if let pairTask, !pairTask.isCancelled {
            notify(
                "Pairing awaiting approval",
                "Look for the Allow prompt inside Teams. The request is re-sent automatically every \(Int(options.pairingRetry)) seconds.",
                .info
            )
            return
        }
        startPairLoop(force: force)
    }

    // MARK: - Pairing

    private func startPairLoop(force: Bool) {
        guard pairTask == nil else { return }
        guard force || autoPair else { return }
        pairTask = Task { [weak self] in
            guard let self else { return }
            defer { self.pairTask = nil }

            if force {
                do {
                    _ = try await self.sendAction(
                        "send-reaction",
                        parameters: ["type": "like"],
                        kind: .pair
                    )
                    self.updateState {
                        $0.detail = "Pairing request sent — approve it in Teams"
                    }
                    self.notify(
                        "Pairing request sent",
                        "A prompt should appear in Teams. Select Allow. If nothing appears, enable Third-party app API in Teams → Settings → Privacy.",
                        .info
                    )
                } catch {
                    self.notify(
                        "Could not request pairing",
                        self.describe(error),
                        .warning
                    )
                }
                return
            }

            do {
                try await Task.sleep(
                    nanoseconds: UInt64(self.options.pairingDelay * 1_000_000_000)
                )
                while !Task.isCancelled,
                      self.isSocketOpen,
                      self.state.canPair,
                      !self.pairedThisSession {
                    do {
                        _ = try await self.sendAction(
                            "send-reaction",
                            parameters: ["type": "like"],
                            kind: .pair
                        )
                        self.updateState {
                            $0.detail = "Pairing request sent — approve it in Teams"
                        }
                    } catch {
                        Log.warn("Pairing request failed: \(self.describe(error))")
                        break
                    }
                    try await Task.sleep(
                        nanoseconds: UInt64(self.options.pairingRetry * 1_000_000_000)
                    )
                }
            } catch {
                // Cancellation is normal here.
            }
        }
    }

    // MARK: - Sending

    private func sendAction(
        _ action: String,
        parameters: [String: Any],
        kind: RequestKind
    ) async throws -> Int {
        guard isSocketOpen, let socket else {
            throw TeamsClientError.notConnected
        }
        nextRequestId += 1
        let requestId = nextRequestId
        pending[requestId] = PendingRequest(
            action: action,
            kind: kind,
            sentAt: Date()
        )
        let frame = try TeamsProtocol.actionFrame(
            action: action,
            parameters: parameters,
            requestId: requestId
        )
        do {
            try await socket.send(.string(frame))
            Log.debug("Sent Teams action \(action) (requestId=\(requestId))")
            return requestId
        } catch {
            pending.removeValue(forKey: requestId)
            session?.invalidateAndCancel()
            throw error
        }
    }

    private func queryStateSoon(delay: TimeInterval) {
        queryTask?.cancel()
        let generation = currentGeneration
        queryTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled,
                  generation == self.currentGeneration,
                  self.isSocketOpen
            else { return }
            do {
                _ = try await self.sendAction("query-state", parameters: [:], kind: .query)
            } catch {
                Log.debug("query-state failed: \(self.describe(error))")
            }
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat(generation: Int) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    try await Task.sleep(
                        nanoseconds: UInt64(self.options.heartbeatInterval * 1_000_000_000)
                    )
                    guard generation == self.currentGeneration,
                          self.isSocketOpen,
                          let socket = self.socket
                    else { return }
                    socket.sendPing { [weak self] error in
                        guard let error else { return }
                        Task { @MainActor in
                            self?.heartbeatFailed(error, generation: generation)
                        }
                    }
                }
            } catch {
                // Cancellation is normal here.
            }
        }
    }

    private func heartbeatFailed(_ error: Error, generation: Int) {
        guard generation == currentGeneration, isSocketOpen else { return }
        Log.warn("Heartbeat failed: \(describe(error))")
        isSocketOpen = false
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    // MARK: - State

    private func setState(_ newState: ClientState) {
        guard newState != state else { return }
        state = newState
        onState?(newState)
    }

    private func updateState(_ mutate: (inout ClientState) -> Void) {
        var next = state
        mutate(&next)
        setState(next)
    }

    private func notify(_ title: String, _ message: String, _ level: NoticeLevel) {
        onNotice?(Notice(title: title, message: message, level: level))
    }

    private func nextReconnectDelay() -> TimeInterval {
        let index = min(max(failureCount - 1, 0), options.reconnectDelays.count - 1)
        return options.reconnectDelays[index]
    }

    private func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
                return "Teams is not accepting local connections. Enable Third-party app API in Teams → Settings → Privacy, or start Teams."
            case .timedOut:
                return "The connection to Teams timed out."
            case .badServerResponse:
                return "Teams rejected the local WebSocket handshake."
            case .cancelled:
                return "The Teams connection was closed."
            default:
                return redact("Network error: \(urlError.localizedDescription)")
            }
        }
        if error is TeamsClientError {
            return error.localizedDescription
        }
        return redact("Teams connection error: \(error.localizedDescription)")
    }

    private func redact(_ text: String) -> String {
        guard let token, !token.isEmpty else { return text }
        return text.replacingOccurrences(of: token, with: "[redacted]")
    }

    private static func validToken(_ token: String) -> Bool {
        !token.isEmpty
            && token.count <= 4096
            && !token.contains("\n")
            && !token.contains("\r")
            && !token.contains("\0")
    }
}

enum TeamsClientError: Error, LocalizedError {
    case invalidEndpoint
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Invalid Teams endpoint"
        case .notConnected:
            return "Teams socket is not open"
        }
    }
}

private final class SocketDelegate: NSObject, URLSessionWebSocketDelegate {
    private weak var client: TeamsClient?
    private let generation: Int

    init(client: TeamsClient, generation: Int) {
        self.client = client
        self.generation = generation
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.client?.socketDidOpen(generation: self.generation)
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.client?.socketDidClose(generation: self.generation)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard error != nil else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.client?.socketDidClose(generation: self.generation)
        }
    }
}

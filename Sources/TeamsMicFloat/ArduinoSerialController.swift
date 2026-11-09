import Darwin
import Foundation

/// Monitors an attached Arduino over USB serial (e.g. /dev/cu.usbmodem*)
/// and translates hardware button clicks into Teams microphone toggle actions.
/// Also forwards mute state back to the Arduino (e.g. MUTED / UNMUTED).
final class ArduinoSerialController: @unchecked Sendable {
    var onToggle: (@Sendable () -> Void)?
    var onStatusChanged: (@Sendable (String) -> Void)?

    private let queue = DispatchQueue(
        label: "com.local.teamsmicfloat.arduino",
        qos: .utility
    )

    private var fd: Int32?
    private var readSource: DispatchSourceRead?
    private var reconnectTimer: DispatchSourceTimer?
    private var running = false
    private var currentPort: String?
    private var connectedAt: Date?
    private var lastToggleTime = Date.distantPast
    private var lineBuffer = Data()

    /// Settle period after DTR reset upon opening port before processing toggle events
    private let settleDuration: TimeInterval = 2.0
    /// Minimum time between processed button toggles
    private let debounceInterval: TimeInterval = 0.3

    var statusDescription: String {
        if let port = currentPort, fd != nil {
            return "Arduino: Connected (\(URL(fileURLWithPath: port).lastPathComponent))"
        } else {
            return "Arduino: Disconnected"
        }
    }

    var isConnected: Bool {
        return fd != nil
    }

    // MARK: - Lifecycle

    func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            Log.info("Starting Arduino serial monitor")
            self.connect()
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.stopReconnectTimer()
            self.disconnect()
            Log.info("Stopped Arduino serial monitor")
        }
    }

    func reconnect() {
        queue.async {
            self.disconnect()
            self.connect()
        }
    }

    func send(_ command: String) {
        queue.async {
            guard let fd = self.fd else { return }
            let payload = command.hasSuffix("\n") ? command : command + "\n"
            payload.utf8CString.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                let len = strlen(base)
                var written = 0
                while written < len {
                    let result = Darwin.write(fd, base + written, len - written)
                    if result > 0 {
                        written += result
                    } else {
                        break
                    }
                }
            }
        }
    }

    // MARK: - Connection

    private func findSerialPort() -> String? {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: "/dev") else {
            return nil
        }
        let matching = entries
            .filter { $0.hasPrefix("cu.usbmodem") || $0.hasPrefix("cu.usbserial") }
            .sorted()
        guard let first = matching.first else { return nil }
        return "/dev/" + first
    }

    private func connect() {
        guard running, fd == nil else { return }

        guard let port = findSerialPort() else {
            notifyStatus("Arduino: Not found")
            scheduleReconnect()
            return
        }

        Log.info("Connecting to Arduino on \(port)...")
        let rawFd = Darwin.open(port, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard rawFd >= 0 else {
            Log.warn("Failed to open \(port): errno \(errno)")
            scheduleReconnect()
            return
        }

        var attrs = termios()
        guard tcgetattr(rawFd, &attrs) == 0 else {
            Log.warn("Failed to get terminal attributes for \(port)")
            Darwin.close(rawFd)
            scheduleReconnect()
            return
        }

        cfmakeraw(&attrs)
        attrs.c_cflag |= tcflag_t(CLOCAL | CREAD)
        attrs.c_cflag &= ~tcflag_t(CSTOPB) // 1 stop bit
        attrs.c_cflag &= ~tcflag_t(PARENB) // no parity
        cfsetispeed(&attrs, speed_t(B115200))
        cfsetospeed(&attrs, speed_t(B115200))

        guard tcsetattr(rawFd, TCSANOW, &attrs) == 0 else {
            Log.warn("Failed to set 115200 baud for \(port)")
            Darwin.close(rawFd)
            scheduleReconnect()
            return
        }

        tcflush(rawFd, TCIOFLUSH)

        self.fd = rawFd
        self.currentPort = port
        self.connectedAt = Date()
        self.lineBuffer.removeAll()
        self.stopReconnectTimer()

        Log.info("Connected to Arduino on \(port) @ 115200 baud")
        notifyStatus(statusDescription)

        let source = DispatchSource.makeReadSource(fileDescriptor: rawFd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readAvailableData()
        }
        source.setCancelHandler {
            Darwin.close(rawFd)
        }
        self.readSource = source
        source.resume()
    }

    private func disconnect() {
        if let source = readSource {
            source.cancel()
            readSource = nil
        } else if let openFd = fd {
            Darwin.close(openFd)
        }
        fd = nil
        currentPort = nil
        connectedAt = nil
        lineBuffer.removeAll()
        notifyStatus(statusDescription)
    }

    private func scheduleReconnect() {
        guard running, reconnectTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3.0, repeating: 3.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.running, self.fd == nil else { return }
            self.connect()
        }
        self.reconnectTimer = timer
        timer.resume()
    }

    private func stopReconnectTimer() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }

    private func notifyStatus(_ msg: String) {
        let handler = onStatusChanged
        DispatchQueue.main.async {
            handler?(msg)
        }
    }

    // MARK: - Reading & Parsing

    private func readAvailableData() {
        guard let fd = self.fd else { return }
        var buffer = [UInt8](repeating: 0, count: 512)
        let bytesRead = Darwin.read(fd, &buffer, buffer.count)

        if bytesRead > 0 {
            lineBuffer.append(buffer, count: bytesRead)
            processLineBuffer()
        } else if bytesRead == 0 {
            // EOF (device disconnected)
            Log.warn("Arduino serial port reached EOF (unplugged)")
            disconnect()
            scheduleReconnect()
        } else {
            let err = errno
            if err != EAGAIN && err != EWOULDBLOCK {
                Log.warn("Arduino read error: errno \(err)")
                disconnect()
                scheduleReconnect()
            }
        }
    }

    private func processLineBuffer() {
        let newline = UInt8(ascii: "\n")
        while let index = lineBuffer.firstIndex(of: newline) {
            let lineData = lineBuffer.prefix(upTo: index)
            lineBuffer.removeSubrange(0...index)

            if let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                if !line.isEmpty {
                    handleLine(line)
                }
            }
        }
    }

    private func handleLine(_ line: String) {
        Log.debug("Arduino <<< \(line)")

        // Ignore messages during the settle window (initial DTR reboot)
        if let connected = connectedAt, Date().timeIntervalSince(connected) < settleDuration {
            Log.info("Arduino boot/settle banner: \(line)")
            return
        }

        if line == "TOGGLE" || line.contains("button=pressed") {
            let now = Date()
            if now.timeIntervalSince(lastToggleTime) >= debounceInterval {
                lastToggleTime = now
                Log.info("Arduino button click detected -> requesting Teams mic toggle")
                let handler = onToggle
                DispatchQueue.main.async {
                    handler?()
                }
            } else {
                Log.debug("Arduino button click ignored (debouncing)")
            }
        }
    }
}

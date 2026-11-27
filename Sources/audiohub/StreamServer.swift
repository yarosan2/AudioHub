import Foundation
import Network

/// Serves captured audio as an endless 16-bit PCM WAV over HTTP — the format the
/// Chromecast Default Media Receiver can play from a plain URL.
///
/// The listener is reachable from the LAN (the speaker must fetch from it), so access is
/// restricted: the URL path contains a random per-route token, only GET/HEAD on that exact
/// path is served, and only to the IP address of the speaker we sent the URL to.
final class PCMStreamServer: AudioSink {
    static let maxRequestBytes = 8_192
    static let maxClients = 2
    /// Audio handed to a client's connection but not yet accepted by the network stack is
    /// capped; a client that falls further behind is disconnected instead of making the
    /// queued sends grow without bound. Default: 3 s of 48 kHz stereo 16-bit.
    static let defaultMaxInFlightBytes = 48_000 * 4 * 3
    let maxInFlightBytes: Int

    private let listener: NWListener
    private let queue = DispatchQueue(label: "audiohub.http")

    /// Touched only on `queue` (connections are started on it, so their completions run there).
    private final class Client {
        let connection: NWConnection
        var inFlight = 0
        init(_ c: NWConnection) { connection = c }
    }
    private var clients: [ObjectIdentifier: Client] = [:]
    private var slowClientDisconnects = 0
    private var maxInFlightSeen = 0

    /// For diagnostics and tests.
    func clientStats() -> (clients: Int, slowDisconnects: Int, maxInFlight: Int) {
        queue.sync { (clients.count, slowClientDisconnects, maxInFlightSeen) }
    }
    private var timer: DispatchSourceTimer?

    // Real-time thread → lock-free ring → `queue`. ~5 s of stereo 16-bit at 48 kHz.
    private let ring = SPSCRing<Int16>(minimumCapacity: 48_000 * 2 * 5, zero: 0)
    private static let maxBlockSamples = 16_384 * 2
    private let produceScratch: UnsafeMutablePointer<Int16>   // RT thread only
    private let drainScratch: UnsafeMutablePointer<Int16>     // `queue` only
    /// Published once by the audio thread, read by the network queue and by callers waiting
    /// for the format. Atomic: no locks or semaphores on the audio thread.
    private let rate = AtomicDouble(0)
    var sampleRate: Double { rate.value }

    private var statBytes = 0
    private var statPeak = 0
    private var statSince = Date()

    /// Unguessable per-route path, e.g. /3f9c…e1/stream.wav
    let path = "/" + (0 ..< 16).map { _ in String(format: "%02x", UInt8.random(in: 0 ... 255)) }.joined() + "/stream.wav"
    var port: UInt16 { listener.port?.rawValue ?? 0 }
    /// Only this client IP is served. nil = nobody yet (set once the speaker is known).
    private var allowedClient: String?
    private var stopped = false

    func allow(client ip: String) {
        queue.sync { allowedClient = Self.normalizeIP(ip) }
    }

    /// Stops listening and drops all clients. Safe to call more than once.
    func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            timer?.cancel()
            listener.cancel()
            clients.values.forEach { $0.connection.cancel() }
            clients.removeAll()
        }
    }

    /// `port` is for tests; normally the system picks a free one.
    init(maxInFlightBytes: Int = PCMStreamServer.defaultMaxInFlightBytes, port: NWEndpoint.Port = .any) throws {
        self.maxInFlightBytes = maxInFlightBytes
        produceScratch = .allocate(capacity: Self.maxBlockSamples)
        drainScratch = .allocate(capacity: 48_000 * 2)
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: port)
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        // Wait for the listener to actually be ready; anything else is an error, not a
        // server without a port (the speaker would be sent a URL nobody answers).
        let settled = DispatchSemaphore(value: 0)
        let outcome = ListenerOutcome()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: outcome.set(nil); settled.signal()
            case .failed(let e): outcome.set(e); settled.signal()
            case .waiting(let e): outcome.set(e); settled.signal()   // e.g. port in use; would retry forever
            case .cancelled: outcome.set(UserError("listener cancelled")); settled.signal()
            default: break
            }
        }
        listener.start(queue: queue)
        let timedOut = settled.wait(timeout: .now() + 3) == .timedOut
        if timedOut || outcome.error != nil || listener.port == nil || listener.port?.rawValue == 0 {
            // Every stored property is set, so deinit runs on this throw and frees the buffers;
            // do not free them here too.
            listener.stateUpdateHandler = nil
            listener.cancel()
            throw UserError("Could not start the audio stream server: \(timedOut ? "timed out" : "\(outcome.error.map { "\($0)" } ?? "no port")")")
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.drain() }
        t.resume()
        timer = t
    }

    deinit {
        // No queue.sync here: the last reference may be dropped on `queue` itself.
        timer?.cancel()
        listener.cancel()
        clients.values.forEach { $0.connection.cancel() }
        produceScratch.deallocate()
        drainScratch.deallocate()
    }

    /// Blocks until audio has started flowing (we need the sample rate for the WAV header).
    func waitForAudioFormat(timeout: TimeInterval) -> Bool {
        // Polls instead of a semaphore so the audio thread never has to signal anything.
        let deadline = Date().addingTimeInterval(timeout)
        while rate.value == 0 {
            if Date() >= deadline { return false }
            usleep(5_000)
        }
        return true
    }

    // MARK: AudioSink (real-time thread)

    func consume(_ stereo: UnsafePointer<Float>, frames: Int, sampleRate: Double) {
        if rate.value == 0 { rate.value = sampleRate }   // only this thread writes it
        // No locks, no allocation: convert into preallocated scratch, then into the ring.
        let n = min(frames * 2, Self.maxBlockSamples)
        for i in 0 ..< n {
            produceScratch[i] = Int16(max(-1, min(1, stereo[i])) * 32767)
        }
        ring.write(produceScratch, count: n)
    }

    // MARK: Networking

    private func drain() {
        let count = ring.read(into: drainScratch, maxCount: 48_000 * 2)
        guard count > 0 else { return }
        // Int16 is little-endian on every Mac, so the samples go out as-is.
        let chunk = Data(bytes: drainScratch, count: count * 2)
        // Diagnostics: bytes delivered and loudest sample, every ~3 s.
        chunk.withUnsafeBytes { raw in
            for s in raw.bindMemory(to: Int16.self) { statPeak = max(statPeak, abs(Int(s))) }
        }
        statBytes += clients.isEmpty ? 0 : chunk.count
        if Date().timeIntervalSince(statSince) > 3 {
            log("stream: clients=\(clients.count) sent=\(statBytes / 1024) KB peak=\(String(format: "%.2f", Double(statPeak) / 32767))")
            statBytes = 0; statPeak = 0; statSince = Date()
        }
        for (key, client) in clients {
            if client.inFlight + chunk.count > maxInFlightBytes {
                // The speaker stopped reading (stalled, or the network can't keep up).
                slowClientDisconnects += 1
                log("stream: client is \(client.inFlight / 1024) KB behind, disconnecting it")
                client.connection.cancel()
                clients[key] = nil
                continue
            }
            client.inFlight += chunk.count
            maxInFlightSeen = max(maxInFlightSeen, client.inFlight)
            let size = chunk.count
            client.connection.send(content: chunk, completion: .contentProcessed { [weak self, weak client] err in
                // Runs on `queue`.
                client?.inFlight -= size
                if err != nil, let self, self.clients[key] != nil {
                    self.clients[key]?.connection.cancel()
                    self.clients[key] = nil
                }
            })
        }
    }

    private func accept(_ c: NWConnection) {
        guard !stopped, clients.count < Self.maxClients else { c.cancel(); return }
        c.start(queue: queue)
        readRequest(c, buffer: Data())
    }

    /// Reads until the end of the request headers (bounded), then answers or rejects.
    private func readRequest(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestBytes) { [weak self] data, _, done, err in
            guard let self else { c.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            let complete = buf.range(of: Data("\r\n\r\n".utf8)) != nil
            if !complete {
                if err == nil, !done, buf.count < Self.maxRequestBytes { self.readRequest(c, buffer: buf) }
                else { self.reply(c, status: 400) }
                return
            }
            Self.dumpIfRequested(buf)
            let request = String(decoding: buf, as: UTF8.self)
            let remote: String
            if case .hostPort(let host, _) = c.endpoint { remote = "\(host)" } else { remote = "" }
            let status = Self.validate(request: request, remoteIP: remote, allowedIP: self.allowedClient, path: self.path)
            log("HTTP \(status) ← \(remote) \(request.split(separator: "\r\n").first.map { Self.redact($0) } ?? "?")")
            guard status == 200 else { self.reply(c, status: status); return }
            var response = Data("HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n".utf8)
            if request.hasPrefix("HEAD ") {
                c.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
                return
            }
            let r = self.rate.value
            response.append(Self.wavHeader(sampleRate: UInt32(r > 0 ? r : 48_000)))
            c.send(content: response, completion: .contentProcessed { _ in })
            self.clients[ObjectIdentifier(c)] = Client(c)
        }
    }

    private func reply(_ c: NWConnection, status: Int) {
        let text = [400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "Error"
        let r = Data("HTTP/1.1 \(status) \(text)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        c.send(content: r, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }

    /// Decides how to answer a request: 200, or 400/403/404/405.
    static func validate(request: String, remoteIP: String, allowedIP: String?, path: String) -> Int {
        // Note: "\r\n" is a single Character in Swift, so split on isNewline, not on "\r".
        let firstLine = request.split(maxSplits: 1, whereSeparator: \.isNewline).first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return 400 }
        guard let allowedIP, normalizeIP(remoteIP) == allowedIP else { return 403 }
        guard parts[0] == "GET" || parts[0] == "HEAD" else { return 405 }
        // Ignore a query string, but the path itself must match exactly.
        guard parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) == path else { return 404 }
        return 200
    }

    /// "192.168.1.5%en0" → "192.168.1.5", "::ffff:192.168.1.5" → "192.168.1.5".
    static func normalizeIP(_ ip: String) -> String {
        var s = ip.split(separator: "%").first.map(String.init) ?? ip
        if s.hasPrefix("[") && s.hasSuffix("]") { s = String(s.dropFirst().dropLast()) }
        if s.lowercased().hasPrefix("::ffff:"), s.contains(".") { s = String(s.dropFirst(7)) }
        return s
    }

    /// Debug: AUDIOHUB_DUMP_HTTP_DIR=<dir> saves every incoming request byte for byte
    /// (used to record test fixtures from real speakers).
    private static func dumpIfRequested(_ raw: Data) {
        guard let dir = ProcessInfo.processInfo.environment["AUDIOHUB_DUMP_HTTP_DIR"] else { return }
        let name = "request-\(Int(Date().timeIntervalSince1970 * 1000)).http"
        try? raw.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    /// Keeps the token out of logs.
    private static func redact(_ line: Substring) -> String {
        line.replacingOccurrences(of: #"/[0-9a-f]{32}/"#, with: "/…/", options: .regularExpression)
    }

    static func wavHeader(sampleRate: UInt32, channels: UInt16 = 2, bits: UInt16 = 16) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let block = channels * bits / 8
        d.append(contentsOf: Array("RIFF".utf8)); u32(0xFFFF_FFFF)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(channels)
        u32(sampleRate); u32(sampleRate * UInt32(block)); u16(block); u16(bits)
        d.append(contentsOf: Array("data".utf8)); u32(0xFFFF_FFFF)
        return d
    }
}

func log(_ s: String) {
    FileHandle.standardError.write("\n[\(Date().formatted(date: .omitted, time: .standard))] \(s)".data(using: .utf8)!)
}

/// Records the first terminal state of a listener (written on its queue, read after a semaphore).
private final class ListenerOutcome {
    private let lock = NSLock()
    private var done = false
    private var _error: Error?
    func set(_ e: Error?) { lock.lock(); if !done { done = true; _error = e }; lock.unlock() }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return _error }
}

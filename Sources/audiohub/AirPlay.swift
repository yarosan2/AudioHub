import AVFoundation
import CryptoKit
import Darwin
import Foundation
import Network
import os

struct AirPlayDevice {
    let name: String
    var paths: [(endpoint: NWEndpoint, interface: NWInterface?)]
    let txt: [String: String]
}

/// Finds AirPlay (RAOP) receivers via Bonjour (_raop._tcp, instance names "MAC@Name").
enum AirPlayDiscovery {
    static func scan(seconds: TimeInterval = 3) -> [AirPlayDevice] {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_raop._tcp", domain: nil), using: .tcp)
        var found: [AirPlayDevice] = []
        let lock = NSLock()
        browser.browseResultsChangedHandler = { results, _ in
            var list: [AirPlayDevice] = []
            for r in results {
                guard case .service(let instance, _, _, _) = r.endpoint else { continue }
                let name = instance.split(separator: "@", maxSplits: 1).last.map(String.init) ?? instance
                var txt: [String: String] = [:]
                if case .bonjour(let t) = r.metadata { txt = t.dictionary }
                let ifaces: [NWInterface?] = r.interfaces.isEmpty ? [nil] : r.interfaces
                let paths = ifaces.map { (endpoint: r.endpoint, interface: $0) }
                if let i = list.firstIndex(where: { $0.name == name }) { list[i].paths += paths }
                else { list.append(AirPlayDevice(name: name, paths: paths, txt: txt)) }
            }
            lock.lock(); found = list; lock.unlock()
        }
        browser.start(queue: DispatchQueue(label: "audiohub.raop.browse"))
        Thread.sleep(forTimeInterval: seconds)
        browser.cancel()
        lock.lock(); defer { lock.unlock() }
        // Never stream to ourselves.
        let me = Host.current().localizedName ?? ""
        return found.filter { $0.name != me }
    }
}

/// Legacy AirPlay (RAOP) sender, unencrypted (et=0): RTSP control, RTP/UDP audio in
/// uncompressed ALAC frames of 352 samples at 44.1 kHz, plus NTP-style timing replies
/// and once-a-second sync packets so the receiver knows when to play each sample.
final class AirPlaySession: AudioSink {
    private static let framesPerPacket = 352
    private static let outputRate = 44_100.0
    private static let latencyFrames: UInt32 = 77_175  // ≈1.75 s, the classic RAOP default

    let device: AirPlayDevice
    var onStatus: ((String) -> Void)?
    /// AirPlay volume in dB: -30 (quiet) … 0 (max). nil = leave the speaker's own volume.
    var volumeDB: Double?

    private let queue = DispatchQueue(label: "audiohub.raop")
    // Separate queue: the speaker asks for our time while we block waiting for SETUP's reply.
    private let timingQueue = DispatchQueue(label: "audiohub.raop.timing", qos: .userInteractive)
    private var rtsp: NWConnection?
    private var cseq = 0
    private var sessionHeader: String?
    private let sessionID = UInt32.random(in: 1 ... .max)
    private let clientInstance = String(format: "%016llX", UInt64.random(in: 1 ... .max))
    private var localIP = "", remoteIP = "", interfaceName: String?
    private var announceURL: String { "rtsp://\(localIP)/\(sessionID)" }

    // UDP
    private var audioSock: Int32 = -1, controlSock: Int32 = -1, timingSock: Int32 = -1
    private var serverAudioPort: UInt16 = 0, serverControlPort: UInt16 = 0
    private var timingSource: DispatchSourceRead?
    private var syncTimer: DispatchSourceTimer?
    private var keepAlive: DispatchSourceTimer?
    private var drainTimer: DispatchSourceTimer?

    // RTP state
    private var seq = UInt16.random(in: 0 ... .max)
    private var rtpTime = UInt32.random(in: 0 ... .max)
    private let ssrc = UInt32.random(in: 0 ... .max)
    private var firstPacket = true, firstSync = true
    private(set) var streaming = false
    // Diagnostics
    private var statPackets = 0, statSendErrors = 0, statPeak: Int16 = 0, statTiming = 0, statTicks = 0

    // Audio path: RT thread → float ring → converter (→44.1k Int16) → packets
    private var lock = os_unfair_lock()
    private let ringCapacity = 48_000 * 2 * 2
    private let ring: UnsafeMutablePointer<Float>
    private var writeIndex = 0, readIndex = 0
    private var inputRate: Double = 0
    private var converter: AVAudioConverter?
    private var pcm: [Int16] = []

    init(device: AirPlayDevice) {
        self.device = device
        ring = .allocate(capacity: ringCapacity)
    }

    deinit { ring.deallocate() }

    // MARK: AudioSink (real-time thread)

    func consume(_ stereo: UnsafePointer<Float>, frames: Int, sampleRate: Double) {
        if inputRate == 0 { inputRate = sampleRate }
        os_unfair_lock_lock(&lock)
        for i in 0 ..< frames * 2 {
            ring[writeIndex] = stereo[i]
            writeIndex = (writeIndex + 1) % ringCapacity
            if writeIndex == readIndex { readIndex = (readIndex + 1) % ringCapacity }
        }
        os_unfair_lock_unlock(&lock)
    }

    // MARK: Lifecycle

    func start() {
        queue.async { self.connect(pathIndex: 0) }
    }

    /// Sets the speaker volume, 0…1. AirPlay uses dB: −30 (quietest) … 0 (max), −144 = mute.
    /// Slider drags produce many calls; only the latest pending value is sent.
    func setVolume(_ level: Double) {
        let db = level <= 0.001 ? -144 : -30 + 30 * min(level, 1)
        queue.async {
            self.volumeDB = db
            guard self.streaming, !self.volumePending else { return }
            self.volumePending = true
            self.queue.asyncAfter(deadline: .now() + 0.1) {
                self.volumePending = false
                guard self.streaming, let v = self.volumeDB else { return }
                _ = try? self.request("SET_PARAMETER", self.announceURL, headers: ["Content-Type": "text/parameters"],
                                      body: String(format: "volume: %.6f\r\n", v), timeout: 2)
            }
        }
    }
    private var volumePending = false

    static func level(fromDB db: Double) -> Double { db <= -30 ? 0 : (db + 30) / 30 }

    func stop() {
        queue.sync {
            [syncTimer, keepAlive, drainTimer].forEach { $0?.cancel() }
            timingSource?.cancel()
            if streaming { _ = try? request("TEARDOWN", announceURL, timeout: 1) }
            streaming = false
            rtsp?.cancel()
            for s in [audioSock, controlSock] where s >= 0 { close(s) }
            audioSock = -1; controlSock = -1
        }
    }

    private func connect(pathIndex: Int) {
        guard pathIndex < device.paths.count else { onStatus?("could not reach \(device.name)"); return }
        let path = device.paths[pathIndex]
        let params = NWParameters.tcp
        if let iface = path.interface { params.requiredInterface = iface }
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let c = NWConnection(to: path.endpoint, using: params)
        let ready = DispatchSemaphore(value: 0)
        c.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        c.start(queue: DispatchQueue(label: "audiohub.raop.tcp"))
        guard ready.wait(timeout: .now() + 4) == .success else {
            onStatus?("via \(path.interface?.name ?? "default"): timeout, trying next interface")
            c.cancel()
            connect(pathIndex: pathIndex + 1)
            return
        }
        rtsp = c
        interfaceName = path.interface?.name
        if case .hostPort(let h, _)? = c.currentPath?.localEndpoint { localIP = Self.ipString(h) }
        if case .hostPort(let h, _)? = c.currentPath?.remoteEndpoint { remoteIP = Self.ipString(h) }
        onStatus?("connected to \(device.name) (\(remoteIP)) via \(interfaceName ?? "default")")
        do {
            try handshake()
        } catch {
            onStatus?("AirPlay setup failed: \(error)")
        }
    }

    private func handshake() throws {
        controlSock = try Self.udpSocket(interface: interfaceName)
        timingSock = try Self.udpSocket(interface: interfaceName)
        audioSock = controlSock  // audio may go out of any socket; reuse control
        listenForTiming()

        _ = try request("OPTIONS", "*")

        // AirPlay 2 speakers advertising MFi-SAP (et contains 4) refuse ANNOUNCE until the
        // sender does "auth-setup": 0x01 followed by a Curve25519 public key. The reply
        // (speaker key + certificate) is not needed for unencrypted streaming.
        let et = (device.txt["et"] ?? "").split(separator: ",")
        if et.contains("4") {
            var body = Data([0x01])
            body.append(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
            _ = try request("POST", "/auth-setup", headers: ["Content-Type": "application/octet-stream"], bodyData: body)
        }

        let sdp = """
        v=0\r
        o=iTunes \(sessionID) 0 IN IP4 \(localIP)\r
        s=iTunes\r
        c=IN IP4 \(remoteIP)\r
        t=0 0\r
        m=audio 0 RTP/AVP 96\r
        a=rtpmap:96 AppleLossless\r
        a=fmtp:96 \(Self.framesPerPacket) 0 16 40 10 14 2 255 0 0 44100\r

        """
        _ = try request("ANNOUNCE", announceURL, headers: ["Content-Type": "application/sdp"], body: sdp)

        let setup = try request("SETUP", announceURL, headers: [
            "Transport": "RTP/AVP/UDP;unicast;interleaved=0-1;mode=record;control_port=\(Self.port(of: controlSock));timing_port=\(Self.port(of: timingSock))",
        ])
        sessionHeader = setup.headers["session"]?.split(separator: ";").first.map(String.init)
        let transport = setup.headers["transport"] ?? ""
        func param(_ key: String) -> UInt16? {
            transport.split(separator: ";").first { $0.hasPrefix(key + "=") }.flatMap { UInt16($0.dropFirst(key.count + 1)) }
        }
        guard let sp = param("server_port") else { throw RTSPError.protocolError("no server_port in \(transport)") }
        serverAudioPort = sp
        serverControlPort = param("control_port") ?? sp + 1

        _ = try request("RECORD", announceURL, headers: ["Range": "npt=0-", "RTP-Info": "seq=\(seq);rtptime=\(rtpTime)"])
        if let v = volumeDB {
            _ = try request("SET_PARAMETER", announceURL, headers: ["Content-Type": "text/parameters"],
                            body: String(format: "volume: %.6f\r\n", v))
        }
        streaming = true
        onStatus?("streaming (audio→\(remoteIP):\(serverAudioPort), latency ≈1.75 s)")
        sendSync()
        startTimers()
    }

    private func startTimers() {
        let sync = DispatchSource.makeTimerSource(queue: queue)
        sync.schedule(deadline: .now() + 1, repeating: 1)
        sync.setEventHandler { [weak self] in
            guard let self else { return }
            self.sendSync()
            self.statTicks += 1
            if self.statTicks % 3 == 0 {
                self.onStatus?("sent \(self.statPackets) packets (errors \(self.statSendErrors)), peak \(String(format: "%.2f", Double(self.statPeak) / 32767)), timing requests \(self.statTiming)")
                self.statPackets = 0; self.statSendErrors = 0; self.statPeak = 0; self.statTiming = 0
            }
        }
        sync.resume(); syncTimer = sync

        let ka = DispatchSource.makeTimerSource(queue: queue)
        ka.schedule(deadline: .now() + 15, repeating: 15)
        ka.setEventHandler { [weak self] in
            guard let self else { return }
            _ = try? self.request("OPTIONS", "*", timeout: 2)
        }
        ka.resume(); keepAlive = ka

        let drain = DispatchSource.makeTimerSource(queue: queue)
        drain.schedule(deadline: .now(), repeating: .milliseconds(5))
        drain.setEventHandler { [weak self] in self?.pump() }
        drain.resume(); drainTimer = drain
    }

    // MARK: Audio packets

    /// Moves captured audio through the resampler and sends every full 352-frame packet.
    private func pump() {
        guard streaming, inputRate > 0 else { return }
        os_unfair_lock_lock(&lock)
        let count = (writeIndex - readIndex + ringCapacity) % ringCapacity
        var floats = [Float](repeating: 0, count: count)
        for i in 0 ..< count { floats[i] = ring[(readIndex + i) % ringCapacity] }
        readIndex = writeIndex
        os_unfair_lock_unlock(&lock)
        guard count >= 2 else { return }
        resample(floats)
        let samplesPerPacket = Self.framesPerPacket * 2
        while pcm.count >= samplesPerPacket {
            let packet = Array(pcm.prefix(samplesPerPacket))
            pcm.removeFirst(samplesPerPacket)
            sendAudio(packet)
        }
    }

    private func resample(_ interleaved: [Float]) {
        let frames = interleaved.count / 2
        let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 2, interleaved: true)!
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.outputRate, channels: 2, interleaved: true)!
        if converter == nil { converter = AVAudioConverter(from: inFormat, to: outFormat) }
        guard let converter, let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        inBuf.frameLength = AVAudioFrameCount(frames)
        interleaved.withUnsafeBufferPointer { src in
            inBuf.mutableAudioBufferList.pointee.mBuffers.mData?.copyMemory(from: src.baseAddress!, byteCount: frames * 8)
        }
        let outCap = AVAudioFrameCount(Double(frames) * Self.outputRate / inputRate) + 64
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCap) else { return }
        var given = false
        var err: NSError?
        converter.convert(to: outBuf, error: &err) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true; status.pointee = .haveData; return inBuf
        }
        guard let p = outBuf.int16ChannelData?[0] else { return }
        pcm.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(outBuf.frameLength) * 2))
    }

    private func sendAudio(_ samples: [Int16]) {
        var pkt = Data(capacity: 12 + samples.count * 2 + 16)
        pkt.append(0x80)
        pkt.append(firstPacket ? 0xE0 : 0x60)
        pkt.appendBE(seq); pkt.appendBE(rtpTime); pkt.appendBE(ssrc)
        pkt.append(Self.alacUncompressed(samples))
        if Self.sendUDP(audioSock, pkt, to: remoteIP, port: serverAudioPort) < 0 { statSendErrors += 1 }
        statPackets += 1
        for v in samples { statPeak = max(statPeak, v == .min ? .max : abs(v)) }
        firstPacket = false
        seq &+= 1
        rtpTime &+= UInt32(Self.framesPerPacket)
    }

    /// "Play RTP time (now − latency) at NTP time now."
    private func sendSync() {
        guard streaming else { return }
        var pkt = Data()
        pkt.append(firstSync ? 0x90 : 0x80)
        pkt.append(0xD4)
        pkt.appendBE(UInt16(7))
        pkt.appendBE(rtpTime &- Self.latencyFrames)
        pkt.append(Self.ntpNow())
        pkt.appendBE(rtpTime)
        Self.sendUDP(controlSock, pkt, to: remoteIP, port: serverControlPort)
        firstSync = false
    }

    /// Answer the receiver's timing requests (0xD2) with our clock (0xD3).
    private func listenForTiming() {
        let src = DispatchSource.makeReadSource(fileDescriptor: timingSock, queue: timingQueue)
        let sock = timingSock
        src.setEventHandler {
            var buf = [UInt8](repeating: 0, count: 128)
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(sock, &buf, buf.count, 0, $0, &len) }
            }
            guard n >= 32, buf[1] & 0x7F == 0x52 else { return }
            self.statTiming += 1
            let now = Self.ntpNow()
            var reply = Data([0x80, 0xD3, 0x00, 0x07, 0, 0, 0, 0])
            reply.append(contentsOf: buf[24 ..< 32])  // their transmit time → our "origin"
            reply.append(now)                         // receive time
            reply.append(Self.ntpNow())               // transmit time
            _ = reply.withUnsafeBytes { raw in
                withUnsafePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(sock, raw.baseAddress, raw.count, 0, $0, len) }
                }
            }
        }
        src.setCancelHandler { close(sock) }
        src.resume()
        timingSource = src
    }

    // MARK: ALAC

    /// Wraps 16-bit stereo PCM in an ALAC frame that uses the "escape" (uncompressed) mode,
    /// so no real encoder is needed. Samples are big-endian after a 55-bit header.
    static func alacUncompressed(_ samples: [Int16]) -> Data {
        var w = BitWriter()
        w.write(1, bits: 3)        // element: channel pair (stereo)
        w.write(0, bits: 4)        // element instance tag
        w.write(0, bits: 12)       // unused
        w.write(1, bits: 1)        // has explicit sample count
        w.write(0, bits: 2)        // bytes shifted
        w.write(1, bits: 1)        // escape: uncompressed
        w.write(UInt32(samples.count / 2), bits: 32)
        for s in samples { w.write(UInt32(UInt16(bitPattern: s)), bits: 16) }
        w.write(7, bits: 3)        // ID_END
        return w.bytes
    }

    // MARK: RTSP

    enum RTSPError: Error { case timeout(String), status(Int, String), protocolError(String) }
    struct Response { let status: Int; let headers: [String: String] }

    @discardableResult
    private func request(_ method: String, _ url: String, headers: [String: String] = [:],
                         body: String? = nil, bodyData rawBody: Data? = nil, timeout: TimeInterval = 5) throws -> Response {
        guard let rtsp else { throw RTSPError.protocolError("not connected") }
        cseq += 1
        var h = headers
        h["CSeq"] = "\(cseq)"
        h["User-Agent"] = "iTunes/7.6.2 (Windows; N;)"
        h["Client-Instance"] = clientInstance
        h["DACP-ID"] = clientInstance
        h["Active-Remote"] = "\(sessionID)"
        if let sessionHeader { h["Session"] = sessionHeader }
        let bodyData = rawBody ?? body.map { Data($0.utf8) } ?? Data()
        if !bodyData.isEmpty { h["Content-Length"] = "\(bodyData.count)" }
        var msg = "\(method) \(url) RTSP/1.0\r\n"
        for (k, v) in h { msg += "\(k): \(v)\r\n" }
        msg += "\r\n"
        var out = Data(msg.utf8); out.append(bodyData)

        let done = DispatchSemaphore(value: 0)
        var received = Data()
        var result: Response?
        rtsp.send(content: out, completion: .contentProcessed { _ in })
        func readMore() {
            rtsp.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, err in
                if let data { received.append(data) }
                if let r = Self.parseResponse(received) { result = r; done.signal() }
                else if err == nil { readMore() } else { done.signal() }
            }
        }
        readMore()
        guard done.wait(timeout: .now() + timeout) == .success, let r = result else { throw RTSPError.timeout(method) }
        if ProcessInfo.processInfo.environment["AUDIOHUB_DEBUG"] != nil { log("RTSP \(method) → \(r.status) \(r.headers)") }
        guard r.status == 200 else { throw RTSPError.status(r.status, method) }
        return r
    }

    private static func parseResponse(_ d: Data) -> Response? {
        // Headers are text, the body may be binary (auth-setup), so split on bytes.
        guard let end = d.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: d[d.startIndex ..< end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ")
        guard statusLine.count >= 2, let code = Int(statusLine[1]) else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        if let len = headers["content-length"].flatMap(Int.init), d.endIndex - end.upperBound < len { return nil }
        return Response(status: code, headers: headers)
    }

    // MARK: Sockets & time

    private static func udpSocket(interface: String?) throws -> Int32 {
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { throw RTSPError.protocolError("socket()") }
        if let interface {
            var idx = if_nametoindex(interface)
            setsockopt(s, IPPROTO_IP, IP_BOUND_IF, &idx, socklen_t(MemoryLayout<UInt32>.size))
        }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_port = 0
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { close(s); throw RTSPError.protocolError("bind()") }
        return s
    }

    private static func port(of sock: Int32) -> UInt16 {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
        }
        return UInt16(bigEndian: addr.sin_port)
    }

    @discardableResult
    private static func sendUDP(_ sock: Int32, _ data: Data, to ip: String, port: UInt16) -> Int {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, ip, &addr.sin_addr)
        return data.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(sock, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private static func ntpNow() -> Data {
        let t = Date().timeIntervalSince1970 + 2_208_988_800
        let secs = UInt32(UInt64(t) & 0xFFFF_FFFF)
        let frac = UInt32(min((t - floor(t)) * 4_294_967_296.0, 4_294_967_295.0))
        var d = Data(); d.appendBE(secs); d.appendBE(frac); return d
    }

    private static func ipString(_ h: NWEndpoint.Host) -> String {
        switch h {
        case .ipv4(let a): return "\(a)".split(separator: "%").first.map(String.init) ?? "\(a)"
        case .ipv6(let a): return "\(a)"
        case .name(let n, _): return n
        @unknown default: return ""
        }
    }
}

struct BitWriter {
    private(set) var data = Data()
    private var acc: UInt64 = 0
    private var count = 0
    mutating func write(_ value: UInt32, bits: Int) {
        acc = (acc << UInt64(bits)) | (UInt64(value) & ((1 << UInt64(bits)) - 1))
        count += bits
        while count >= 8 {
            count -= 8
            data.append(UInt8((acc >> UInt64(count)) & 0xFF))
        }
        acc &= (1 << UInt64(count)) - 1
    }
    /// Bytes written so far, with the last partial byte zero-padded.
    var bytes: Data { var c = self; if c.count > 0 { c.write(0, bits: 8 - c.count) }; return c.data }
}

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ v: T) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
}

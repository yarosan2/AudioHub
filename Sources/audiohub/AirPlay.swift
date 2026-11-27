import AVFoundation
import CryptoKit
import Darwin
import Foundation
import Network

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
    private var rtsp: RTSPClient?
    private var sessionHeader: String?
    private let sessionID = UInt32.random(in: 1 ... .max)
    private let clientInstance = String(format: "%016llX", UInt64.random(in: 1 ... .max))
    private var localIP = "", remoteIP = "", interfaceName: String?
    private var announceURL: String { "rtsp://\(localIP)/\(sessionID)" }

    // UDP. Audio and control packets share `controlSock` (RAOP allows any source port).
    // Each socket is closed exactly once: by its read source's cancel handler once the
    // source exists (`controlSource`, `timingSource`), otherwise directly in stop().
    private var controlSock: Int32 = -1, timingSock: Int32 = -1
    private var serverAudioPort: UInt16 = 0, serverControlPort: UInt16 = 0
    private var timingSource: DispatchSourceRead?
    private var controlSource: DispatchSourceRead?
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
    private var statResendRequests = 0, statResent = 0, statResendMisses = 0

    /// Recently sent RTP packets, for answering the speaker's retransmission requests.
    /// Touched only on `queue` (sending happens in pump(), requests are read on `queue`).
    private var history = PacketHistory(size: 512)   // ≈4 s at 125 packets/s
    /// Debug: AUDIOHUB_DROP_EVERY=N skips sending every Nth packet (to exercise resends).
    private let debugDropEvery = ProcessInfo.processInfo.environment["AUDIOHUB_DROP_EVERY"].flatMap(Int.init) ?? 0

    // Audio path: RT thread → lock-free float ring → converter (→44.1k Int16) → packets.
    // Everything on the consumer side is allocated once, when the first audio arrives.
    private let ring = SPSCRing<Float>(minimumCapacity: 48_000 * 2 * 2, zero: 0)
    private var inputRate: Double = 0
    private var converter: AVAudioConverter?
    private var inBuffer: AVAudioPCMBuffer?
    private var outBuffer: AVAudioPCMBuffer?
    private static let chunkFrames: AVAudioFrameCount = 4_096
    private var pcm: [Int16] = []
    private var pcmStart = 0

    init(device: AirPlayDevice) {
        self.device = device
    }

    // MARK: AudioSink (real-time thread)

    func consume(_ stereo: UnsafePointer<Float>, frames: Int, sampleRate: Double) {
        if inputRate == 0 { inputRate = sampleRate }
        ring.write(stereo, count: frames * 2)   // lock-free, no allocation
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
            if streaming { _ = try? request("TEARDOWN", announceURL, timeout: 1) }
            streaming = false
            rtsp?.close()
            if let controlSource { controlSource.cancel() } else if controlSock >= 0 { close(controlSock) }
            if let timingSource { timingSource.cancel() } else if timingSock >= 0 { close(timingSock) }
            controlSource = nil; timingSource = nil
            controlSock = -1; timingSock = -1
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
        rtsp = RTSPClient(connection: c)
        rtsp?.onLateResponse = { r in log("RTSP: dropped late response (CSeq \(r.cseq.map(String.init) ?? "?"))") }
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
        listenForTiming()
        listenForControl()

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
        guard let sp = param("server_port") else { throw RTSPClient.RTSPError.protocolError("no server_port in \(transport)") }
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
                self.onStatus?("sent \(self.statPackets) packets (errors \(self.statSendErrors)), peak \(String(format: "%.2f", Double(self.statPeak) / 32767)), timing requests \(self.statTiming), resend requests \(self.statResendRequests) → resent \(self.statResent), too old \(self.statResendMisses)")
                self.statPackets = 0; self.statSendErrors = 0; self.statPeak = 0; self.statTiming = 0
                self.statResendRequests = 0; self.statResent = 0; self.statResendMisses = 0
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
        if converter == nil { setUpConverter() }
        guard let converter, let inBuffer, let outBuffer,
              let src = inBuffer.floatChannelData?[0] else { return }
        // Drain the ring in fixed-size chunks through the preallocated buffers.
        while true {
            let samples = ring.read(into: src, maxCount: Int(Self.chunkFrames) * 2)
            guard samples >= 2 else { break }
            inBuffer.frameLength = AVAudioFrameCount(samples / 2)
            outBuffer.frameLength = 0
            var given = false
            var err: NSError?
            converter.convert(to: outBuffer, error: &err) { _, status in
                if given { status.pointee = .noDataNow; return nil }
                given = true; status.pointee = .haveData; return inBuffer
            }
            if let p = outBuffer.int16ChannelData?[0] {
                pcm.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(outBuffer.frameLength) * 2))
            }
            if samples < Int(Self.chunkFrames) * 2 { break }
        }
        let samplesPerPacket = Self.framesPerPacket * 2
        while pcm.count - pcmStart >= samplesPerPacket {
            sendAudio(Array(pcm[pcmStart ..< pcmStart + samplesPerPacket]))
            pcmStart += samplesPerPacket
        }
        // Compact occasionally instead of shifting the array on every packet.
        if pcmStart > 32_768 { pcm.removeFirst(pcmStart); pcmStart = 0 }
    }

    private func setUpConverter() {
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 2, interleaved: true),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.outputRate, channels: 2, interleaved: true)
        else { return }
        converter = AVAudioConverter(from: inFormat, to: outFormat)
        inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: Self.chunkFrames)
        let outCap = AVAudioFrameCount(Double(Self.chunkFrames) * Self.outputRate / inputRate) + 256
        outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCap)
        pcm.reserveCapacity(65_536)
    }

    private func sendAudio(_ samples: [Int16]) {
        var pkt = Data(capacity: 12 + samples.count * 2 + 16)
        pkt.append(0x80)
        pkt.append(firstPacket ? 0xE0 : 0x60)
        pkt.appendBE(seq); pkt.appendBE(rtpTime); pkt.appendBE(ssrc)
        pkt.append(Self.alacUncompressed(samples))
        history.store(seq: seq, packet: pkt)
        let skip = debugDropEvery > 0 && Int(seq) % debugDropEvery == 0 && !firstPacket
        if !skip, Self.sendUDP(controlSock, pkt, to: remoteIP, port: serverAudioPort) < 0 { statSendErrors += 1 }
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

    /// Reads the control port: the speaker asks for lost packets there (payload type 0x55).
    private func listenForControl() {
        let sock = controlSock
        let src = DispatchSource.makeReadSource(fileDescriptor: sock, queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 2048)
            let n = recv(sock, &buf, buf.count, 0)
            guard n > 0 else { return }
            let reply = Self.retransmissions(for: Array(buf[0 ..< n]), history: self.history)
            guard let reply else { return }
            self.statResendRequests += 1
            self.statResent += reply.packets.count
            self.statResendMisses += reply.missing
            for p in reply.packets { Self.sendUDP(sock, p, to: self.remoteIP, port: self.serverControlPort) }
        }
        src.setCancelHandler { close(sock) }
        src.resume()
        controlSource = src
    }

    /// Parses a RAOP resend request (0x80 0xD5, seq, first missing seq, count) and builds the
    /// replies: each is 0x80 0xD6 + 2 bytes + the original RTP packet. Packets no longer in
    /// `history` are counted as missing. nil if `request` is not a resend request.
    static func retransmissions(for request: [UInt8], history: PacketHistory) -> (packets: [Data], missing: Int)? {
        guard request.count >= 8, request[1] & 0x7F == 0x55 else { return nil }
        let first = UInt16(request[4]) << 8 | UInt16(request[5])
        let count = min(Int(UInt16(request[6]) << 8 | UInt16(request[7])), history.size)
        var packets: [Data] = []
        var missing = 0
        for i in 0 ..< count {
            let seq = first &+ UInt16(truncatingIfNeeded: i)
            guard let original = history.packet(seq: seq) else { missing += 1; continue }
            var p = Data([0x80, 0xD6, 0x00, 0x01])
            p.append(original)
            packets.append(p)
        }
        return (packets, missing)
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

    /// Adds the headers every RAOP request carries and hands it to the RTSP client.
    @discardableResult
    private func request(_ method: String, _ url: String, headers: [String: String] = [:],
                         body: String? = nil, bodyData rawBody: Data? = nil,
                         timeout: TimeInterval = 5) throws -> RTSPClient.Response {
        guard let rtsp else { throw RTSPClient.RTSPError.closed }
        var h = headers
        h["User-Agent"] = "iTunes/7.6.2 (Windows; N;)"
        h["Client-Instance"] = clientInstance
        h["DACP-ID"] = clientInstance
        h["Active-Remote"] = "\(sessionID)"
        if let sessionHeader { h["Session"] = sessionHeader }
        return try rtsp.request(method, url, headers: h,
                                body: rawBody ?? body.map { Data($0.utf8) } ?? Data(), timeout: timeout)
    }

    // MARK: Sockets & time

    private static func udpSocket(interface: String?) throws -> Int32 {
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { throw RTSPClient.RTSPError.protocolError("socket()") }
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
        guard ok == 0 else { close(s); throw RTSPClient.RTSPError.protocolError("bind()") }
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

/// The last `size` RTP packets, addressed by sequence number (which wraps at 65536).
struct PacketHistory {
    let size: Int
    private var seqs: [UInt16]
    private var packets: [Data?]

    init(size: Int) {
        self.size = size
        seqs = Array(repeating: 0, count: size)
        packets = Array(repeating: nil, count: size)
    }

    mutating func store(seq: UInt16, packet: Data) {
        let i = Int(seq) % size
        seqs[i] = seq
        packets[i] = packet
    }

    /// The packet with exactly this sequence number, if it is still remembered.
    func packet(seq: UInt16) -> Data? {
        let i = Int(seq) % size
        return seqs[i] == seq ? packets[i] : nil
    }
}

import Foundation
import Network

struct CastDevice {
    let name: String
    let model: String
    /// The same speaker as seen through each network interface. A Mac with two NICs on one
    /// subnet can only reach it through some of them, so we try each in turn.
    var paths: [(endpoint: NWEndpoint, interface: NWInterface?)]
}

/// Finds Google Cast devices on the LAN via Bonjour (_googlecast._tcp).
enum CastDiscovery {
    static func scan(seconds: TimeInterval = 3) -> [CastDevice] {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil), using: .tcp)
        var found: [CastDevice] = []
        let lock = NSLock()
        browser.browseResultsChangedHandler = { results, _ in
            var list: [CastDevice] = []
            for r in results {
                var name = "Chromecast", model = ""
                if case .bonjour(let txt) = r.metadata {
                    name = txt["fn"] ?? name
                    model = txt["md"] ?? ""
                }
                let ifaces: [NWInterface?] = r.interfaces.isEmpty ? [nil] : r.interfaces
                let paths = ifaces.map { (endpoint: r.endpoint, interface: $0) }
                if let i = list.firstIndex(where: { $0.name == name }) {
                    list[i].paths += paths
                } else {
                    list.append(CastDevice(name: name, model: model, paths: paths))
                }
            }
            lock.lock(); found = list; lock.unlock()
        }
        browser.start(queue: DispatchQueue(label: "audiohub.cast.browse"))
        Thread.sleep(forTimeInterval: seconds)
        browser.cancel()
        lock.lock(); defer { lock.unlock() }
        return found
    }
}

/// Minimal Google Cast v2 sender: TLS on port 8009, length-prefixed protobuf `CastMessage`
/// frames with JSON payloads. Launches the Default Media Receiver and makes it play our URL.
final class CastSession {
    private static let defaultReceiver = "CC1AD845"
    private enum NS {
        static let connection = "urn:x-cast:com.google.cast.tp.connection"
        static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
        static let receiver = "urn:x-cast:com.google.cast.receiver"
        static let media = "urn:x-cast:com.google.cast.media"
    }

    let device: CastDevice
    private let queue = DispatchQueue(label: "audiohub.cast")
    private var connection: NWConnection?
    private var buffer = Data()
    private var requestID = 1
    private var transportID: String?
    private var sessionID: String?
    /// Builds the media URL from (our LAN IP, the speaker's IP).
    private var mediaURL: ((String, String) -> String)?
    private var heartbeat: DispatchSourceTimer?
    var onStatus: ((String) -> Void)?
    /// Speaker volume 0…1 as reported by the device (also after changes made on the speaker itself).
    var onVolume: ((Double) -> Void)?

    init(device: CastDevice) { self.device = device }

    /// Connects and plays `url(localIP)`. The closure receives the Mac's LAN IP as seen on the
    /// path to the speaker, so the URL is reachable from it.
    func play(url: @escaping (_ localIP: String, _ speakerIP: String) -> String) {
        mediaURL = url
        queue.async { self.connect(pathIndex: 0) }
    }

    private func connect(pathIndex: Int) {
        guard pathIndex < device.paths.count else {
            onStatus?("could not reach \(device.name) through any network interface")
            return
        }
        let path = device.paths[pathIndex]
        let tls = NWProtocolTLS.Options()
        // Cast devices use self-signed certificates.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, done in done(true) }, queue)
        let params = NWParameters(tls: tls)
        if let iface = path.interface { params.requiredInterface = iface }
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let c = NWConnection(to: path.endpoint, using: params)
        connection = c
        var settled = false
        let tryNext = { [weak self] (reason: String) in
            guard let self, !settled else { return }
            settled = true
            self.onStatus?("via \(path.interface?.name ?? "default"): \(reason), trying next interface")
            c.cancel()
            self.connect(pathIndex: pathIndex + 1)
        }
        queue.asyncAfter(deadline: .now() + 4) { if c.state != .ready { tryNext("timeout") } }
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                settled = true
                self.onStatus?("connected to \(self.device.name) via \(path.interface?.name ?? "default")")
                self.send(NS.connection, ["type": "CONNECT"], to: "receiver-0")
                self.send(NS.receiver, ["type": "LAUNCH", "appId": Self.defaultReceiver, "requestId": self.nextID()], to: "receiver-0")
                self.startHeartbeat()
                self.receive()
            case .failed(let e):
                if settled { self.onStatus?("cast connection lost: \(e)") } else { tryNext("\(e)") }
            case .waiting(let e): tryNext("\(e)")
            default: break
            }
        }
        c.start(queue: queue)
    }

    func stop() {
        queue.sync {
            if let sessionID { send(NS.receiver, ["type": "STOP", "sessionId": sessionID, "requestId": nextID()], to: "receiver-0") }
            heartbeat?.cancel()
        }
        Thread.sleep(forTimeInterval: 0.3)
        connection?.cancel()
    }

    func setVolume(_ level: Double) {
        queue.async {
            self.send(NS.receiver, ["type": "SET_VOLUME", "volume": ["level": level], "requestId": self.nextID()], to: "receiver-0")
        }
    }

    private func nextID() -> Int { requestID += 1; return requestID }

    private func startHeartbeat() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.send(NS.heartbeat, ["type": "PING"], to: "receiver-0") }
        t.resume()
        heartbeat = t
    }

    private var localIP: String? { Self.ip(connection?.currentPath?.localEndpoint) }
    private var remoteIP: String? { Self.ip(connection?.currentPath?.remoteEndpoint) }

    private static func ip(_ endpoint: NWEndpoint?) -> String? {
        guard case .hostPort(let host, _)? = endpoint else { return nil }
        switch host {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a): return "[\(a)]"
        case .name(let n, _): return n
        @unknown default: return nil
        }
    }

    private func handle(namespace: String, source: String, json: [String: Any]) {
        let type = json["type"] as? String ?? ""
        switch (namespace, type) {
        case (NS.heartbeat, "PING"):
            send(NS.heartbeat, ["type": "PONG"], to: source)
        case (NS.receiver, "RECEIVER_STATUS"):
            if let vol = (json["status"] as? [String: Any])?["volume"] as? [String: Any] {
                onStatus?("speaker volume: \(vol["level"] ?? "?") muted: \(vol["muted"] ?? "?")")
                if let level = vol["level"] as? Double { onVolume?(level) }
            }
            let apps = (json["status"] as? [String: Any])?["applications"] as? [[String: Any]] ?? []
            guard transportID == nil,
                  let app = apps.first(where: { $0["appId"] as? String == Self.defaultReceiver }),
                  let tid = app["transportId"] as? String else { return }
            transportID = tid
            sessionID = app["sessionId"] as? String
            send(NS.connection, ["type": "CONNECT"], to: tid)
            guard let ip = localIP, let speaker = remoteIP, let url = mediaURL?(ip, speaker) else {
                onStatus?("cannot determine local IP"); return
            }
            onStatus?("loading \(url.replacingOccurrences(of: #"/[0-9a-f]{32}/"#, with: "/…/", options: .regularExpression))")
            send(NS.media, [
                "type": "LOAD", "requestId": nextID(), "autoplay": true, "currentTime": 0,
                "media": [
                    "contentId": url, "contentType": "audio/wav", "streamType": "LIVE",
                    "metadata": ["metadataType": 3, "title": "AudioHub", "artist": Host.current().localizedName ?? "Mac"],
                ],
            ], to: tid)
        case (NS.media, "MEDIA_STATUS"):
            if let s = (json["status"] as? [[String: Any]])?.first, let state = s["playerState"] as? String {
                onStatus?("player: \(state)\((s["idleReason"] as? String).map { " (\($0))" } ?? "")")
            }
        case (NS.media, "LOAD_FAILED"), (NS.media, "LOAD_CANCELLED"), (NS.media, "INVALID_REQUEST"),
             (NS.receiver, "LAUNCH_ERROR"):
            onStatus?("error: \(json)")
        default: break
        }
    }

    // MARK: Framing

    private func send(_ namespace: String, _ payload: [String: Any], to destination: String) {
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: json, encoding: .utf8) else { return }
        var msg = Data()
        Proto.varintField(1, 0, into: &msg)                // protocol_version = CASTV2_1_0
        Proto.stringField(2, "sender-0", into: &msg)        // source_id
        Proto.stringField(3, destination, into: &msg)       // destination_id
        Proto.stringField(4, namespace, into: &msg)         // namespace
        Proto.varintField(5, 0, into: &msg)                 // payload_type = STRING
        Proto.stringField(6, text, into: &msg)              // payload_utf8
        var frame = Data()
        withUnsafeBytes(of: UInt32(msg.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(msg)
        connection?.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data { self.buffer.append(data); self.parseFrames() }
            if err == nil && !done { self.receive() } else { self.onStatus?("cast connection closed") }
        }
    }

    private func parseFrames() {
        while buffer.count >= 4 {
            let len = Int(buffer.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard buffer.count >= 4 + len else { return }
            let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + len)
            buffer.removeFirst(4 + len)
            let fields = Proto.decodeStrings(body)
            if let ns = fields[4], let payload = fields[6],
               let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] {
                handle(namespace: ns, source: fields[2] ?? "receiver-0", json: obj)
            }
        }
    }
}

/// Just enough protobuf for CastMessage.
enum Proto {
    static func varint(_ v: UInt64, into d: inout Data) {
        var v = v
        while v >= 0x80 { d.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        d.append(UInt8(v))
    }
    static func varintField(_ n: UInt64, _ v: UInt64, into d: inout Data) { varint(n << 3, into: &d); varint(v, into: &d) }
    static func stringField(_ n: UInt64, _ s: String, into d: inout Data) {
        let b = Data(s.utf8)
        varint(n << 3 | 2, into: &d); varint(UInt64(b.count), into: &d); d.append(b)
    }
    static func decodeStrings(_ d: Data) -> [Int: String] {
        var out: [Int: String] = [:]
        let bytes = [UInt8](d)
        var i = 0
        func readVarint() -> UInt64? {
            var r: UInt64 = 0, shift: UInt64 = 0
            while i < bytes.count {
                let b = bytes[i]; i += 1
                r |= UInt64(b & 0x7F) << shift
                if b < 0x80 { return r }
                shift += 7
            }
            return nil
        }
        while i < bytes.count, let key = readVarint() {
            let field = Int(key >> 3)
            switch key & 7 {
            case 0: _ = readVarint()
            case 2:
                guard let len = readVarint(), i + Int(len) <= bytes.count else { return out }
                out[field] = String(bytes: bytes[i ..< i + Int(len)], encoding: .utf8)
                i += Int(len)
            default: return out
            }
        }
        return out
    }
}

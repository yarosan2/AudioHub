import Foundation
import Network

/// `audiohub selftest` — automated checks that need no speakers.
/// Each check prints PASS/FAIL; the process exits non-zero if anything failed.
enum SelfTest {
    private static var failures = 0

    static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            print("PASS  \(name)")
        } else {
            failures += 1
            let d = detail()
            print("FAIL  \(name)\(d.isEmpty ? "" : " — \(d)")")
        }
    }

    static func run() -> Never {
        alacFraming()
        httpValidation()
        httpServerLive()
        castFraming()
        rtspParsing()
        rtspLive()
        print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: HTTP stream server

    static func httpValidation() {
        let p = "/0123456789abcdef0123456789abcdef/stream.wav"
        let ok = "192.168.1.6"
        // Real clients send headers after the request line; include some.
        func v(_ req: String, ip: String = ok, allowed: String? = ok) -> Int {
            let withHeaders = req.replacingOccurrences(of: "\r\n\r\n", with: "\r\nHost: 192.168.1.2:5000\r\nUser-Agent: CrKey\r\n\r\n")
            return PCMStreamServer.validate(request: withHeaders, remoteIP: ip, allowedIP: allowed, path: p)
        }
        check("HTTP GET on the token path from the speaker → 200", v("GET \(p) HTTP/1.1\r\n\r\n") == 200)
        check("HTTP HEAD → 200", v("HEAD \(p) HTTP/1.1\r\n\r\n") == 200)
        check("HTTP query string ignored → 200", v("GET \(p)?x=1 HTTP/1.1\r\n\r\n") == 200)
        check("HTTP wrong token → 404", v("GET /ffff/stream.wav HTTP/1.1\r\n\r\n") == 404)
        check("HTTP old fixed path → 404", v("GET /stream.wav HTTP/1.1\r\n\r\n") == 404)
        check("HTTP path prefix trick → 404", v("GET \(p)/../x HTTP/1.1\r\n\r\n") == 404)
        check("HTTP POST → 405", v("POST \(p) HTTP/1.1\r\n\r\n") == 405)
        check("HTTP other host → 403", v("GET \(p) HTTP/1.1\r\n\r\n", ip: "192.168.1.99") == 403)
        check("HTTP nobody allowed yet → 403", v("GET \(p) HTTP/1.1\r\n\r\n", allowed: nil) == 403)
        check("HTTP garbage → 400", v("hello") == 400)
        check("HTTP IPv4-mapped / scoped address normalized",
              v("GET \(p) HTTP/1.1\r\n\r\n", ip: "::ffff:192.168.1.6") == 200
              && v("GET \(p) HTTP/1.1\r\n\r\n", ip: "192.168.1.6%en0") == 200)
    }

    /// Starts a real server on this Mac and talks to it over TCP.
    static func httpServerLive() {
        guard let server = try? PCMStreamServer() else { check("HTTP server starts", false); return }
        defer { server.stop() }
        let port = server.port
        check("HTTP server listening", port != 0)

        func get(_ path: String) -> String {
            String(decoding: TCPClient.exchange(port: port, "GET \(path) HTTP/1.1\r\nHost: x\r\n\r\n", readBytes: 200), as: UTF8.self)
        }
        check("live: rejected before the speaker is known", get(server.path).hasPrefix("HTTP/1.1 403"))
        server.allow(client: "127.0.0.1")
        let good = get(server.path)
        check("live: allowed client gets 200 + WAV header", good.hasPrefix("HTTP/1.1 200") && good.contains("RIFF") && good.contains("WAVE"))
        check("live: wrong token → 404", get("/stream.wav").hasPrefix("HTTP/1.1 404"))
        server.allow(client: "10.255.255.1")
        check("live: other client → 403", get(server.path).hasPrefix("HTTP/1.1 403"))
        let huge = TCPClient.exchange(port: port, String(repeating: "A", count: 20_000), readBytes: 100)
        check("live: oversized request rejected", String(decoding: huge, as: UTF8.self).hasPrefix("HTTP/1.1 400") || huge.isEmpty)
        server.stop()
        check("live: stopped server refuses connections", TCPClient.exchange(port: port, "GET / HTTP/1.1\r\n\r\n", readBytes: 10).isEmpty)
    }

    // MARK: Cast framing

    static func castFraming() {
        func frame(_ body: [UInt8]) -> Data {
            var d = Data(); d.appendBE(UInt32(body.count)); d.append(contentsOf: body); return d
        }
        var f = CastFramer()
        let two = frame([1, 2, 3]) + frame([4])
        check("Cast: two frames in one read", (try? f.feed(two)) == [Data([1, 2, 3]), Data([4])])

        var g = CastFramer()
        let whole = frame(Array(repeating: 7, count: 1000))
        let a = (try? g.feed(whole.prefix(2))) ?? [Data()]
        let b = (try? g.feed(whole.dropFirst(2).prefix(500))) ?? [Data()]
        let c = (try? g.feed(whole.dropFirst(502))) ?? []
        check("Cast: frame split across reads", a.isEmpty && b.isEmpty && c == [Data(repeating: 7, count: 1000)])

        var h = CastFramer()
        check("Cast: 64 KiB frame accepted", (try? h.feed(frame(Array(repeating: 0, count: 65_536))))?.count == 1)

        var k = CastFramer()
        var huge = Data(); huge.appendBE(UInt32(0x7FFF_FFFF))
        var threw = false
        do { _ = try k.feed(huge) } catch { threw = true }
        check("Cast: oversized length rejected from the header alone", threw)
    }

    // MARK: RTSP

    static func rtspParsing() {
        let r = Data("RTSP/1.0 200 OK\r\nCSeq: 3\r\nContent-Length: 4\r\n\r\n\r\n\r\nRTSP/1.0".utf8)
        if case .response(let resp, let used) = RTSPClient.parse(r) {
            check("RTSP parse: binary body containing CRLFCRLF", resp.cseq == 3 && resp.body == Data("\r\n\r\n".utf8) && used == r.count - 8)
        } else { check("RTSP parse: binary body containing CRLFCRLF", false) }
        if case .incomplete = RTSPClient.parse(Data("RTSP/1.0 200 OK\r\nContent-Length: 10\r\n\r\nabc".utf8)) {
            check("RTSP parse: waits for the whole body", true)
        } else { check("RTSP parse: waits for the whole body", false) }
        if case .invalid = RTSPClient.parse(Data("HTTP/1.1 200 OK\r\n\r\n".utf8)) {
            check("RTSP parse: rejects non-RTSP status line", true)
        } else { check("RTSP parse: rejects non-RTSP status line", false) }
    }

    /// Runs RTSPClient against a scripted fake server on 127.0.0.1.
    static func rtspLive() {
        func reply(_ cseq: Int, _ extra: String = "") -> String {
            "RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\n\(extra)\r\n"
        }

        // 1. Response delivered in two pieces.
        withRTSP({ conn in
            _ = conn.readRequest()
            let r = reply(1, "X-Test: split\r\n")
            conn.write(String(r.prefix(10))); usleep(100_000); conn.write(String(r.dropFirst(10)))
        }) { client in
            let r = try? client.request("OPTIONS", "*")
            check("RTSP live: response split across packets", r?.headers["x-test"] == "split")
        }

        // 2. Two concurrent requests answered in reverse order in one write.
        withRTSP({ conn in
            let a = conn.readRequest(), b = conn.readRequest()
            conn.write(reply(max(a, b), "X-For: \(max(a, b))\r\n") + reply(min(a, b), "X-For: \(min(a, b))\r\n"))
        }) { client in
            var r1: RTSPClient.Response?, r2: RTSPClient.Response?
            let g = DispatchGroup()
            DispatchQueue.global().async(group: g) { r1 = try? client.request("OPTIONS", "*") }
            usleep(50_000)
            DispatchQueue.global().async(group: g) { r2 = try? client.request("GET_PARAMETER", "*") }
            g.wait()
            check("RTSP live: out-of-order responses reach the right request",
                  r1?.headers["x-for"] == "1" && r2?.headers["x-for"] == "2")
        }

        // 3. A late response must not be taken as the next request's answer (the old bug).
        withRTSP({ conn in
            let first = conn.readRequest()
            let second = conn.readRequest()          // sent after the first timed out
            conn.write(reply(first, "X-For: late\r\n"))
            usleep(100_000)
            conn.write(reply(second, "X-For: second\r\n"))
        }) { client in
            var lateSeen = false
            client.onLateResponse = { _ in lateSeen = true }
            let first = Result { try client.request("OPTIONS", "*", timeout: 0.3) }
            let second = try? client.request("OPTIONS", "*", timeout: 2)
            usleep(50_000)
            var timedOut = false
            if case .failure(let e) = first, case .timeout = e as? RTSPClient.RTSPError { timedOut = true }
            check("RTSP live: first request times out", timedOut)
            check("RTSP live: late response is dropped, next request gets its own", second?.headers["x-for"] == "second" && lateSeen)
        }

        // 4. Server closes the connection: the waiting request fails at once, not after the timeout.
        withRTSP({ conn in
            _ = conn.readRequest()
            usleep(100_000)
            conn.closeNow()
        }) { client in
            let t = Date()
            var closed = false
            do { _ = try client.request("OPTIONS", "*", timeout: 5) } catch let e as RTSPClient.RTSPError {
                if case .closed = e { closed = true }
            } catch {}
            check("RTSP live: closed connection fails the request immediately", closed && Date().timeIntervalSince(t) < 2)
            var after = false
            do { _ = try client.request("OPTIONS", "*", timeout: 1) } catch { after = true }
            check("RTSP live: requests after close fail", after)
        }

        // 5. Non-200 status is reported as an error.
        withRTSP({ conn in
            let c = conn.readRequest()
            conn.write("RTSP/1.0 403 Forbidden\r\nCSeq: \(c)\r\n\r\n")
        }) { client in
            var got403 = false
            do { _ = try client.request("ANNOUNCE", "rtsp://x/1") } catch let e as RTSPClient.RTSPError {
                if case .status(403, _) = e { got403 = true }
            } catch {}
            check("RTSP live: non-200 becomes an error", got403)
        }
    }

    /// Starts a one-connection fake server, connects an RTSPClient to it, runs `test`.
    private static func withRTSP(_ server: @escaping (FakeConnection) -> Void, test: (RTSPClient) -> Void) {
        guard let fake = FakeServer(handler: server) else { check("fake RTSP server starts", false); return }
        let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: fake.port)!, using: .tcp)
        let ready = DispatchSemaphore(value: 0)
        c.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        c.start(queue: DispatchQueue(label: "selftest.rtsp"))
        guard ready.wait(timeout: .now() + 2) == .success else { check("connect to fake RTSP server", false); return }
        let client = RTSPClient(connection: c)
        test(client)
        client.close()
        fake.finish()
    }

    // MARK: ALAC

    static func alacFraming() {
        let samples: [Int16] = (0 ..< 704).map { Int16(truncatingIfNeeded: $0 * 97 - 30_000) }
        let frame = AirPlaySession.alacUncompressed(samples)
        // 3+4+12+1+2+1 header bits + 32-bit count + 16 bits per sample + 3-bit end tag, padded.
        let expectedBits = 23 + 32 + samples.count * 16 + 3
        check("ALAC frame size", frame.count == (expectedBits + 7) / 8, "\(frame.count) bytes")
        let b = [UInt8](frame)
        check("ALAC header: stereo element, escape flag", b[0] == 0x20 && b[1] == 0x00 && b[2] & 0x12 == 0x12)
        // Sample count sits right after the 23-bit header.
        var r = BitReader(b); r.skip(23)
        check("ALAC sample count", r.read(32) == 352)
        let decoded = (0 ..< samples.count).map { _ in Int16(bitPattern: UInt16(r.read(16))) }
        check("ALAC samples round-trip", decoded == samples)
        check("ALAC end tag", r.read(3) == 7)
    }
}

struct BitReader {
    private let bytes: [UInt8]
    private var pos = 0
    init(_ b: [UInt8]) { bytes = b }
    mutating func skip(_ n: Int) { pos += n }
    mutating func read(_ n: Int) -> UInt32 {
        var v: UInt32 = 0
        for _ in 0 ..< n {
            let bit = (bytes[pos / 8] >> (7 - UInt8(pos % 8))) & 1
            v = v << 1 | UInt32(bit)
            pos += 1
        }
        return v
    }
}

/// Tiny blocking TCP client for loopback tests.
enum TCPClient {
    static func exchange(port: UInt16, _ request: String, readBytes: Int, timeout: TimeInterval = 2) -> [UInt8] {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { return [] }
        _ = request.utf8CString.withUnsafeBufferPointer { send(fd, $0.baseAddress, $0.count - 1, 0) }
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 4096)
        while out.count < readBytes {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            out += buf[0 ..< n]
        }
        return out
    }
}

/// One-shot TCP server on 127.0.0.1 for scripted protocol tests.
final class FakeServer {
    let port: UInt16
    private let listenFD: Int32
    private let done = DispatchSemaphore(value: 0)

    init?(handler: @escaping (FakeConnection) -> Void) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 1) == 0 else { close(fd); return nil }
        var got = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        port = UInt16(bigEndian: got.sin_port)
        listenFD = fd
        let done = self.done
        Thread.detachNewThread {
            let c = accept(fd, nil, nil)
            if c >= 0 {
                let conn = FakeConnection(fd: c)
                handler(conn)
                conn.waitForPeerClose()
                conn.closeNow()
            }
            done.signal()
        }
    }

    func finish() {
        _ = done.wait(timeout: .now() + 3)
        close(listenFD)
    }
}

final class FakeConnection {
    private let fd: Int32
    private var buffer = Data()
    private var closed = false
    init(fd: Int32) {
        self.fd = fd
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Reads one request (headers only) and returns its CSeq, or -1.
    func readRequest() -> Int {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { return -1 }
            buffer.append(contentsOf: chunk[0 ..< n])
        }
        let end = buffer.range(of: Data("\r\n\r\n".utf8))!
        let head = String(decoding: buffer[buffer.startIndex ..< end.lowerBound], as: UTF8.self)
        buffer.removeSubrange(buffer.startIndex ..< end.upperBound)
        for line in head.split(whereSeparator: \.isNewline) where line.lowercased().hasPrefix("cseq:") {
            return Int(line.dropFirst(5).trimmingCharacters(in: .whitespaces)) ?? -1
        }
        return -1
    }

    func write(_ s: String) {
        _ = s.utf8CString.withUnsafeBufferPointer { send(fd, $0.baseAddress, $0.count - 1, 0) }
    }

    func waitForPeerClose() {
        guard !closed else { return }
        var b = [UInt8](repeating: 0, count: 256)
        while recv(fd, &b, b.count, 0) > 0 {}
    }

    func closeNow() {
        guard !closed else { return }
        closed = true
        close(fd)
    }
}

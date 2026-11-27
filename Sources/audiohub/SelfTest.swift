import Foundation

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

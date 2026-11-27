import CryptoKit
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

    /// Where recorded fixtures live; `selftest --fixtures <dir>` overrides (default: Tests/Fixtures,
    /// relative to the current directory, i.e. run it from the repository root).
    static var fixturesDir = "Tests/Fixtures"

    static func run(arguments: [String] = []) -> Never {
        if let i = arguments.firstIndex(of: "--fixtures"), i + 1 < arguments.count { fixturesDir = arguments[i + 1] }
        ringBuffer()
        ringBufferStress()
        alacFraming()
        airplayResend()
        stereoDelay()
        httpValidation()
        httpServerLive()
        chromecastFixture()
        updateVersions()
        updateReleaseParsing()
        updateSignatures()
        updateCodeIdentity()
        updateInstallFlow()
        castFraming()
        rtspParsing()
        rtspLive()
        print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Lock-free ring buffer

    static func ringBuffer() {
        let ring = SPSCRing<Int32>(minimumCapacity: 6, zero: 0)
        check("ring: capacity rounds up to a power of two", ring.capacity == 8)
        var src: [Int32] = Array(0 ..< 10)
        var dst = [Int32](repeating: -1, count: 16)
        let wrote = ring.write(&src, count: 10)
        check("ring: full buffer takes only what fits", wrote == 8 && ring.dropped == 2)
        let read = ring.read(into: &dst, maxCount: 16)
        check("ring: reads back in order", read == 8 && Array(dst[0 ..< 8]) == Array(0 ..< 8))
        check("ring: empty read returns 0", ring.read(into: &dst, maxCount: 16) == 0)
        // Wrap-around: positions now at 8; write 5, read 3, write 5 → crosses the end.
        var a: [Int32] = [100, 101, 102, 103, 104], b: [Int32] = [105, 106, 107, 108, 109]
        ring.write(&a, count: 5)
        _ = ring.read(into: &dst, maxCount: 3)
        ring.write(&b, count: 5)
        let n = ring.read(into: &dst, maxCount: 16)
        check("ring: wrap-around keeps order", n == 7 && Array(dst[0 ..< 7]) == [103, 104, 105, 106, 107, 108, 109])
    }

    /// Two threads, odd chunk sizes, a small buffer: every value must arrive exactly once, in order.
    static func ringBufferStress() {
        let total = 20_000_000
        let ring = SPSCRing<Int64>(minimumCapacity: 1_000, zero: 0)
        let producerDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var buf = [Int64](repeating: 0, count: 257)
            var next: Int64 = 0
            var chunk = 1
            while next < total {
                chunk = chunk % 257 + 1
                let n = min(chunk, total - Int(next))
                for i in 0 ..< n { buf[i] = next + Int64(i) }
                var sent = 0
                while sent < n {   // retry instead of dropping, so the sequence must be complete
                    sent += buf.withUnsafeBufferPointer { ring.write($0.baseAddress! + sent, count: n - sent) }
                }
                next += Int64(n)
            }
            producerDone.signal()
        }
        var expected: Int64 = 0
        var ok = true
        var out = [Int64](repeating: 0, count: 300)
        var chunk = 7
        let start = Date()
        while expected < total && Date().timeIntervalSince(start) < 30 {
            chunk = chunk % 300 + 1
            let n = ring.read(into: &out, maxCount: chunk)
            for i in 0 ..< n where out[i] != expected + Int64(i) { ok = false }
            expected += Int64(n)
            if !ok { break }
        }
        _ = producerDone.wait(timeout: .now() + 5)
        check("ring stress: 20M values across threads, none lost or reordered", ok && expected == total,
              "got \(expected) of \(total)")
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

    /// The request a real Chromecast sent (Tests/Fixtures/chromecast-get.http). It must always be
    /// accepted: a parser bug once rejected every request that had headers, and hand-written
    /// test requests without headers did not notice.
    static func chromecastFixture() {
        let url = URL(fileURLWithPath: fixturesDir).appendingPathComponent("chromecast-get.http")
        guard let raw = try? Data(contentsOf: url) else {
            // A missing fixture is a failure, never a skip: otherwise the regression could return unnoticed.
            check("fixture: chromecast-get.http present", false, "not found at \(url.path); run from the repo root or pass --fixtures <dir>")
            return
        }
        let text = String(decoding: raw, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        check("fixture: intact (CRLF endings, 8 headers, blank line)",
              raw.suffix(4) == Data("\r\n\r\n".utf8) && lines.count == 11
              && !text.replacingOccurrences(of: "\r\n", with: "").contains("\n")
              && text.contains("CAST-DEVICE-CAPABILITIES:"))
        let path = "/0123456789abcdef0123456789abcdef/stream.wav"
        check("fixture: real Chromecast request passes validation",
              PCMStreamServer.validate(request: text, remoteIP: "192.0.2.6", allowedIP: "192.0.2.6", path: path) == 200)
        check("fixture: same request from another host is refused",
              PCMStreamServer.validate(request: text, remoteIP: "192.0.2.7", allowedIP: "192.0.2.6", path: path) == 403)

        // Through the real server, bytes as recorded (only the per-route token swapped in).
        guard let server = try? PCMStreamServer() else { check("fixture: server starts", false); return }
        defer { server.stop() }
        server.allow(client: "127.0.0.1")
        let live = text.replacingOccurrences(of: path, with: server.path)
        let reply = String(decoding: TCPClient.exchange(port: server.port, live, readBytes: 200), as: UTF8.self)
        check("fixture: real Chromecast request gets 200 + WAV from the live server",
              reply.hasPrefix("HTTP/1.1 200") && reply.contains("RIFF"))
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

    // MARK: AirPlay retransmission

    static func airplayResend() {
        var h = PacketHistory(size: 512)
        // Sequence numbers 65000 … 65535, 0 … 199: crosses the 16-bit wrap.
        var seq: UInt16 = 65_000
        for _ in 0 ..< 736 { h.store(seq: seq, packet: Data([0x80, 0x60, UInt8(seq >> 8), UInt8(seq & 0xFF)])); seq &+= 1 }

        func req(_ first: UInt16, _ count: UInt16) -> [UInt8] {
            [0x80, 0xD5, 0x00, 0x01, UInt8(first >> 8), UInt8(first & 0xFF), UInt8(count >> 8), UInt8(count & 0xFF)]
        }
        let r = AirPlaySession.retransmissions(for: req(65_534, 4), history: h)
        let seqsOut = r?.packets.map { UInt16($0[6]) << 8 | UInt16($0[7]) }
        check("resend: range across the 16-bit wrap", seqsOut == [65_534, 65_535, 0, 1] && r?.missing == 0)
        check("resend: reply = 0x80 0xD6 + original packet",
              r?.packets.first.map { Array($0.prefix(4)) == [0x80, 0xD6, 0x00, 0x01] && $0.count == 8 } == true)
        let old = AirPlaySession.retransmissions(for: req(65_000, 2), history: h)   // overwritten by now
        check("resend: packets older than the history are reported missing", old?.packets.isEmpty == true && old?.missing == 2)
        let huge = AirPlaySession.retransmissions(for: req(100, 0xFFFF), history: h)
        check("resend: absurd counts are capped", (huge?.packets.count ?? 0) + (huge?.missing ?? 0) <= 512)
        check("resend: other control packets ignored", AirPlaySession.retransmissions(for: [0x80, 0xD4, 0, 7, 0, 0, 0, 0], history: h) == nil)
    }

    // MARK: Stereo pair delay line

    final class CaptureSink: AudioSink {
        var left: [Float] = []
        func consume(_ stereo: UnsafePointer<Float>, frames: Int, sampleRate: Double) {
            for f in 0 ..< frames { left.append(stereo[2 * f]) }   // splitter outputs mono pairs
        }
    }

    /// Feeds `input(i)` through a splitter in 512-frame blocks; `atFrame` runs before each block.
    static func runSplitter(_ split: StereoSplitSink, frames: Int, input: (Int) -> Float, atFrame: (Int) -> Void) {
        var block = [Float](repeating: 0, count: 1024)
        var i = 0
        while i < frames {
            atFrame(i)
            let n = min(512, frames - i)
            for f in 0 ..< n { let v = input(i + f); block[2 * f] = v; block[2 * f + 1] = v }
            block.withUnsafeBufferPointer { split.consume($0.baseAddress!, frames: n, sampleRate: 48_000) }
            i += n
        }
    }

    static func stereoDelay() {
        // 1. Exact delay: an impulse comes out 100 ms (4800 samples) later on the right only.
        let l1 = CaptureSink(), r1 = CaptureSink()
        let s1 = StereoSplitSink(left: l1, right: r1)
        s1.delayMs = 100
        runSplitter(s1, frames: 40_000, input: { $0 == 20_000 ? 1 : 0 }, atFrame: { _ in })
        let li = l1.left.firstIndex { $0 > 0.5 }, ri = r1.left.firstIndex { $0 > 0.5 }
        check("stereo: delay is exact to the sample (right +4800)", li == 20_000 && ri == 24_800, "left \(li ?? -1), right \(ri ?? -1)")

        // 2. Moving the slider while a 50 Hz tone plays must not create a step.
        func maxStep(fadeless: Bool) -> Float {
            let l = CaptureSink(), r = CaptureSink()
            let s = StereoSplitSink(left: l, right: r)
            if fadeless {
                // Control experiment: a tap with a 1-sample "fade" jumps like the old code did.
                var tap = DelayTap()
                var line = [Float](repeating: 0, count: 96_000)
                var out: [Float] = []
                for i in 0 ..< 96_000 {
                    line[i] = 0.5 * sin(2 * .pi * 50 * Float(i) / 48_000)
                    tap.retarget(i < 48_000 ? 0 : 1_790, fadeLength: 1)
                    out.append(line.withUnsafeMutableBufferPointer { tap.next(from: $0.baseAddress!, write: i, capacity: 96_000) })
                }
                return zip(out.dropFirst(), out).map { abs($0 - $1) }.max() ?? 0
            }
            runSplitter(s, frames: 96_000, input: { 0.5 * sin(2 * .pi * 50 * Float($0) / 48_000) },
                        atFrame: { i in if i == 48_128 { s.delayMs = 37.3 } })
            return zip(r.left.dropFirst(), r.left).map { abs($0 - $1) }.max() ?? 0
        }
        let smooth = maxStep(fadeless: false), jump = maxStep(fadeless: true)
        // A 50 Hz sine at 0.5 changes by at most ~0.0033 per sample on its own.
        check("stereo: delay change is click-free (max step \(String(format: "%.4f", smooth)))", smooth < 0.01)
        check("stereo: control — an instant jump would step by \(String(format: "%.2f", jump))", jump > 0.1)

        // 3. Several quick changes in a row settle on the last value.
        let l3 = CaptureSink(), r3 = CaptureSink()
        let s3 = StereoSplitSink(left: l3, right: r3)
        runSplitter(s3, frames: 60_000, input: { $0 == 50_000 ? 1 : 0 },
                    atFrame: { i in if i == 1_024 { s3.delayMs = 10 }; if i == 1_536 { s3.delayMs = 20 }; if i == 2_048 { s3.delayMs = -50 } })
        let l3i = l3.left.firstIndex { $0 > 0.5 }, r3i = r3.left.firstIndex { $0 > 0.5 }
        check("stereo: rapid changes end at the last value (left +2400)", l3i == 52_400 && r3i == 50_000, "left \(l3i ?? -1), right \(r3i ?? -1)")
    }

    // MARK: Updates

    static func updateVersions() {
        check("version: 0.10.0 > 0.9.9", AppVersion.isNewer("0.10.0", than: "0.9.9"))
        check("version: v0.3.0 > 0.2.0 (leading v)", AppVersion.isNewer("v0.3.0", than: "0.2.0"))
        check("version: 1.2 == 1.2.0", AppVersion.compare("1.2", "1.2.0") == .orderedSame)
        check("version: same is not newer", !AppVersion.isNewer("0.2.0", than: "0.2.0"))
        check("version: older is not newer", !AppVersion.isNewer("0.1.9", than: "0.2.0"))
        check("version: suffix ignored (1.0.0-beta == 1.0.0)", AppVersion.compare("1.0.0-beta", "1.0.0") == .orderedSame)
    }

    static func updateReleaseParsing() {
        let url = URL(fileURLWithPath: fixturesDir).appendingPathComponent("github-release-latest.json")
        guard let data = try? Data(contentsOf: url) else {
            check("fixture: github-release-latest.json present", false, "not found at \(url.path)")
            return
        }
        let r = try? ReleaseInfo.parse(data)
        check("release: real GitHub response parses (v0.2.0)", r?.version == "0.2.0"
              && r?.pageURL.absoluteString == "https://github.com/yarosan2/AudioHub/releases/tag/v0.2.0")
        check("release: zip asset found with its size",
              r?.zipURL?.lastPathComponent == "AudioHub-0.2.0.zip" && r?.zipSize == 357_923)
        check("release: without a .sig it is not installable (notify only)", r?.signatureURL == nil && r?.isInstallable == false)

        // Same response with a signature attached.
        var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        var assets = obj["assets"] as? [[String: Any]] ?? []
        assets.append(["name": "AudioHub-0.2.0.zip.sig", "size": 89,
                       "browser_download_url": "https://github.com/yarosan2/AudioHub/releases/download/v0.2.0/AudioHub-0.2.0.zip.sig"])
        obj["assets"] = assets
        let signed = (try? JSONSerialization.data(withJSONObject: obj)).flatMap { try? ReleaseInfo.parse($0) }
        check("release: with zip + .sig it is installable", signed?.isInstallable == true)
        check("release: garbage is rejected", (try? ReleaseInfo.parse(Data("{}".utf8))) == nil)

        check("download hosts: github.com and its CDN allowed",
              UpdateConfig.isAllowedDownload(URL(string: "https://github.com/a/b/releases/download/v1/x.zip")!)
              && UpdateConfig.isAllowedDownload(URL(string: "https://objects.githubusercontent.com/x")!)
              && UpdateConfig.isAllowedDownload(URL(string: "https://release-assets.githubusercontent.com/x")!))
        check("download hosts: others and plain http refused",
              !UpdateConfig.isAllowedDownload(URL(string: "https://evil.example/x.zip")!)
              && !UpdateConfig.isAllowedDownload(URL(string: "http://github.com/x.zip")!)
              && !UpdateConfig.isAllowedDownload(URL(string: "https://github.com.evil.example/x.zip")!))
    }

    static func updateSignatures() {
        let key = Curve25519.Signing.PrivateKey(), other = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        let data = Data((0 ..< 10_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let sig = (try? UpdateSignature.sign(data, with: key)) ?? ""
        check("signature: valid one verifies", UpdateSignature.verify(data, signature: sig + "\n", publicKey: pub))
        var tampered = data; tampered[5_000] ^= 1
        check("signature: one flipped bit fails", !UpdateSignature.verify(tampered, signature: sig, publicKey: pub))
        let wrong = (try? UpdateSignature.sign(data, with: other)) ?? ""
        check("signature: another key fails", !UpdateSignature.verify(data, signature: wrong, publicKey: pub))
        check("signature: garbage fails", !UpdateSignature.verify(data, signature: "not base64!", publicKey: pub)
              && !UpdateSignature.verify(data, signature: sig, publicKey: "AAAA"))
    }

    /// The running selftest binary is build/AudioHub.app, so its identity is the reference.
    static func updateCodeIdentity() {
        guard let req = CodeIdentity.runningAppRequirement(), !CodeIdentity.runningAppIsAdHoc else {
            print("SKIP  code identity: this build is ad-hoc signed (run scripts/make-signing-cert.sh)")
            return
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ah-ident-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let copy = tmp.appendingPathComponent("AudioHub.app")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: Bundle.main.bundleURL, to: copy)
        check("code identity: identical copy accepted", CodeIdentity.validate(copy, against: req))

        let res = copy.appendingPathComponent("Contents/Resources/en.lproj/Localizable.strings")
        let original = try? Data(contentsOf: res)
        try? Data("/* tampered */".utf8).write(to: res)
        check("code identity: modified resource rejected", !CodeIdentity.validate(copy, against: req))
        try? original?.write(to: res)

        _ = shell("/usr/bin/codesign", ["-s", "-", "-f", copy.path])
        check("code identity: ad-hoc re-signed copy rejected", !CodeIdentity.validate(copy, against: req))
    }

    /// End to end against a local fake of the GitHub API: good update installs, bad ones never touch the app.
    static func updateInstallFlow() {
        guard let req = CodeIdentity.runningAppRequirement(), !CodeIdentity.runningAppIsAdHoc,
              let cert = signingCertificateHash() else {
            print("SKIP  install flow: needs the AudioHub Local Signing certificate")
            return
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ah-update-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let current = AppVersion.current

        /// A copy of this build with another version, signed with `identity` (cert hash or "-"), zipped.
        func makeArchive(version: String, identity: String) -> Data? {
            let dir = root.appendingPathComponent("src-\(UUID().uuidString)")
            let app = dir.appendingPathComponent("AudioHub.app")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            guard (try? fm.copyItem(at: Bundle.main.bundleURL, to: app)) != nil else { return nil }
            _ = shell("/usr/bin/plutil", ["-replace", "CFBundleShortVersionString", "-string", version,
                                          app.appendingPathComponent("Contents/Info.plist").path])
            _ = shell("/usr/bin/codesign", ["-s", identity, "-i", "local.audiohub", "-f", app.path])
            let zip = dir.appendingPathComponent("a.zip")
            _ = shell("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path])
            return try? Data(contentsOf: zip)
        }
        func freshTarget() -> URL {
            let dir = root.appendingPathComponent("installed-\(UUID().uuidString)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let app = dir.appendingPathComponent("AudioHub.app")
            try? fm.copyItem(at: Bundle.main.bundleURL, to: app)
            return app
        }
        func version(of app: URL) -> String {
            let d = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
            let p = d.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
            return p?["CFBundleShortVersionString"] as? String ?? "?"
        }

        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        guard let good = makeArchive(version: "99.0.0", identity: cert),
              let adhoc = makeArchive(version: "99.0.0", identity: "-"),
              let same = makeArchive(version: current, identity: cert) else {
            check("install flow: test archives built", false); return
        }
        let server = StaticHTTPServer()
        defer { server.stop() }
        guard server.port != 0 else { check("install flow: local server starts", false); return }
        UpdateConfig.apiBaseOverride = URL(string: "http://127.0.0.1:\(server.port)")
        defer { UpdateConfig.apiBaseOverride = nil }

        /// Publishes `zip` as release `version` with `signature`, then runs the installer on a fresh copy.
        func attempt(_ name: String, version: String, zip: Data, signature: String, advertisedSize: Int? = nil)
            -> (result: Result<Void, Error>, target: URL) {
            let base = "http://127.0.0.1:\(server.port)"
            server.routes = [
                "/repos/test/app/releases/latest": Data("""
                {"tag_name":"v\(version)","html_url":"https://github.com/test/app/releases/tag/v\(version)","body":"",
                 "assets":[{"name":"AudioHub-\(version).zip","size":\(advertisedSize ?? zip.count),
                            "browser_download_url":"\(base)/dl/AudioHub-\(version).zip"},
                           {"name":"AudioHub-\(version).zip.sig","size":\(signature.utf8.count),
                            "browser_download_url":"\(base)/dl/AudioHub-\(version).zip.sig"}]}
                """.utf8),
                "/dl/AudioHub-\(version).zip": zip,
                "/dl/AudioHub-\(version).zip.sig": Data(signature.utf8),
            ]
            let target = freshTarget()
            let result: Result<Void, Error> = blocking {
                let data = try await UpdateInstaller.fetch(
                    UpdateConfig.apiBase.appendingPathComponent("repos/test/app/releases/latest"), limit: 1_000_000)
                let release = try ReleaseInfo.parse(data)
                try await UpdateInstaller(release: release, publicKey: pub, target: target, requirement: req).run()
            }
            return (result, target)
        }
        let sign = { (d: Data) in (try? UpdateSignature.sign(d, with: key)) ?? "" }

        let ok = attempt("good", version: "99.0.0", zip: good, signature: sign(good))
        if case .failure(let e) = ok.result { print("      error: \(e)") }
        check("install flow: signed, newer, same identity → installed",
              (try? ok.result.get()) != nil && version(of: ok.target) == "99.0.0" && CodeIdentity.validate(ok.target, against: req))

        func refused(_ label: String, _ a: (result: Result<Void, Error>, target: URL)) {
            var failed = false
            if case .failure(let e) = a.result { failed = true; print("      reason: \(e)") }
            check("install flow: \(label) → refused, installed app untouched",
                  failed && version(of: a.target) == current && CodeIdentity.validate(a.target, against: req))
        }
        var tampered = good; tampered[tampered.count / 2] ^= 0xFF
        refused("tampered archive", attempt("tampered", version: "99.0.0", zip: tampered, signature: sign(good)))
        let otherKey = (try? UpdateSignature.sign(good, with: Curve25519.Signing.PrivateKey())) ?? ""
        refused("signed with another key", attempt("otherkey", version: "99.0.0", zip: good, signature: otherKey))
        refused("app signed by a different identity", attempt("adhoc", version: "99.0.0", zip: adhoc, signature: sign(adhoc)))
        refused("not newer than installed", attempt("same", version: current, zip: same, signature: sign(same)))
        refused("size differs from the release", attempt("size", version: "99.0.0", zip: good, signature: sign(good),
                                                         advertisedSize: good.count + 1))
    }

    static func signingCertificateHash() -> String? {
        let out = shell("/usr/bin/security", ["find-identity", "-p", "codesigning"])
        return out.split(separator: "\n").first { $0.contains("\"AudioHub Local Signing\"") }?
            .split(separator: " ").dropFirst().first.map(String.init)
    }

    @discardableResult
    static func shell(_ tool: String, _ args: [String]) -> String {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func blocking<T>(_ work: @escaping () async throws -> T) -> Result<T, Error> {
        let sem = DispatchSemaphore(value: 0)
        var out: Result<T, Error>!
        Task.detached {
            do { out = .success(try await work()) } catch { out = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return out
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

/// Loopback HTTP server with a fixed path → body map (for the update flow test).
final class StaticHTTPServer {
    var routes: [String: Data] = [:]
    private let listener: NWListener?
    private let queue = DispatchQueue(label: "selftest.http")
    var port: UInt16 { listener?.port?.rawValue ?? 0 }

    init() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try? NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener?.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener?.newConnectionHandler = { [weak self] c in self?.serve(c) }
        listener?.start(queue: queue)
        _ = ready.wait(timeout: .now() + 2)
    }

    func stop() { listener?.cancel() }

    private func serve(_ c: NWConnection, buffer: Data = Data()) {
        if buffer.isEmpty { c.start(queue: queue) }
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            guard buf.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if data != nil { self.serve(c, buffer: buf) } else { c.cancel() }
                return
            }
            let line = String(decoding: buf, as: UTF8.self).split(whereSeparator: \.isNewline).first ?? ""
            let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let body = self.routes[path]
            var out = Data("HTTP/1.1 \(body == nil ? "404 Not Found" : "200 OK")\r\nContent-Length: \(body?.count ?? 0)\r\nConnection: close\r\n\r\n".utf8)
            if let body { out.append(body) }
            c.send(content: out, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
        }
    }
}

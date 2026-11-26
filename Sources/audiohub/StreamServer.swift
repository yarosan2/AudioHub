import Foundation
import Network
import os

/// Serves captured audio as an endless 16-bit PCM WAV over HTTP — the format the
/// Chromecast Default Media Receiver can play from a plain URL.
final class PCMStreamServer: AudioSink {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "audiohub.http")
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var timer: DispatchSourceTimer?

    // Ring buffer filled on the real-time thread, drained on `queue`.
    private var lock = os_unfair_lock()
    private let ringCapacity = 48_000 * 2 * 4  // ~4 s of stereo samples
    private let ring: UnsafeMutablePointer<Int16>
    private var writeIndex = 0
    private var readIndex = 0
    private(set) var sampleRate: Double = 0
    private let rateKnown = DispatchSemaphore(value: 0)

    private var statBytes = 0
    private var statPeak = 0
    private var statSince = Date()

    let path = "/stream.wav"
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init() throws {
        ring = .allocate(capacity: ringCapacity)
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.drain() }
        t.resume()
        timer = t
    }

    deinit {
        timer?.cancel()
        listener.cancel()
        clients.values.forEach { $0.cancel() }
        ring.deallocate()
    }

    /// Blocks until audio has started flowing (we need the sample rate for the WAV header).
    func waitForAudioFormat(timeout: TimeInterval) -> Bool {
        if sampleRate > 0 { return true }
        let ok = rateKnown.wait(timeout: .now() + timeout) == .success
        if ok { rateKnown.signal() }
        return ok
    }

    // MARK: AudioSink (real-time thread)

    func consume(_ stereo: UnsafePointer<Float>, frames: Int, sampleRate: Double) {
        if self.sampleRate == 0 { self.sampleRate = sampleRate; rateKnown.signal() }
        os_unfair_lock_lock(&lock)
        for i in 0..<(frames * 2) {
            let s = max(-1, min(1, stereo[i]))
            ring[writeIndex] = Int16(s * 32767)
            writeIndex = (writeIndex + 1) % ringCapacity
            if writeIndex == readIndex { readIndex = (readIndex + 1) % ringCapacity }  // overrun: drop oldest
        }
        os_unfair_lock_unlock(&lock)
    }

    // MARK: Networking

    private func drain() {
        os_unfair_lock_lock(&lock)
        var chunk = Data()
        if writeIndex != readIndex {
            let count = (writeIndex - readIndex + ringCapacity) % ringCapacity
            chunk.reserveCapacity(count * 2)
            var i = readIndex
            for _ in 0..<count {
                withUnsafeBytes(of: ring[i].littleEndian) { chunk.append(contentsOf: $0) }
                i = (i + 1) % ringCapacity
            }
            readIndex = writeIndex
        }
        os_unfair_lock_unlock(&lock)
        guard !chunk.isEmpty else { return }
        // Diagnostics: bytes delivered and loudest sample, every ~3 s.
        chunk.withUnsafeBytes { raw in
            for s in raw.bindMemory(to: Int16.self) { statPeak = max(statPeak, abs(Int(s))) }
        }
        statBytes += clients.isEmpty ? 0 : chunk.count
        if Date().timeIntervalSince(statSince) > 3 {
            log("stream: clients=\(clients.count) sent=\(statBytes / 1024) KB peak=\(String(format: "%.2f", Double(statPeak) / 32767))")
            statBytes = 0; statPeak = 0; statSince = Date()
        }
        for (key, c) in clients {
            c.send(content: chunk, completion: .contentProcessed { [weak self] err in
                if err != nil { self?.queue.async { self?.clients[key]?.cancel(); self?.clients[key] = nil } }
            })
        }
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            log("HTTP ← \(request.split(separator: "\r\n").first ?? "?")")
            let isHead = request.hasPrefix("HEAD")
            var response = "HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nCache-Control: no-cache\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
                .data(using: .utf8)!
            if isHead {
                c.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
                return
            }
            response.append(Self.wavHeader(sampleRate: UInt32(self.sampleRate > 0 ? self.sampleRate : 48_000)))
            c.send(content: response, completion: .contentProcessed { _ in })
            self.clients[ObjectIdentifier(c)] = c
        }
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

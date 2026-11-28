import Foundation
import Network

/// RTSP over one TCP connection, with a single persistent read loop.
///
/// Every response is routed to the request whose CSeq it carries, so late responses
/// (after a timeout) and out-of-order responses can never be mistaken for the answer to a
/// different request. A closed or failed connection fails all waiting requests at once.
final class RTSPClient {
    enum RTSPError: Error, CustomStringConvertible {
        case timeout(String), status(Int, String), closed, protocolError(String)
        var description: String {
            switch self {
            case .timeout(let m): return "RTSP \(m) timed out"
            case .status(let c, let m): return "RTSP \(m) → \(c)"
            case .closed: return "RTSP connection closed"
            case .protocolError(let s): return "RTSP protocol error: \(s)"
            }
        }
    }

    struct Response {
        let status: Int
        let headers: [String: String]   // lower-cased names
        let body: Data
        var cseq: Int? { headers["cseq"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
    }

    /// Responses larger than this are treated as a protocol error (auth-setup replies are < 1 KB).
    static let maxResponseBytes = 256 * 1024

    private final class Pending {
        let done = DispatchSemaphore(value: 0)
        var result: Result<Response, Error>?
    }

    private let connection: NWConnection
    private let lock = NSLock()
    private var buffer = Data()
    private var pending: [Int: Pending] = [:]
    private var nextCSeq = 1
    private var closedError: Error?
    var onLateResponse: ((Response) -> Void)?

    /// `connection` must already be in the ready state.
    init(connection: NWConnection) {
        self.connection = connection
        readLoop()
    }

    func close() {
        fail(with: RTSPError.closed)
        connection.cancel()
    }

    /// Sends a request and waits for the response with the same CSeq.
    /// Throws on timeout, on a non-200 status, or if the connection goes away.
    @discardableResult
    func request(_ method: String, _ url: String, headers: [String: String] = [:],
                 body: Data = Data(), timeout: TimeInterval = 5) throws -> Response {
        let entry = Pending()
        lock.lock()
        if let closedError { lock.unlock(); throw closedError }
        let cseq = nextCSeq
        nextCSeq += 1
        pending[cseq] = entry
        lock.unlock()

        var msg = "\(method) \(url) RTSP/1.0\r\nCSeq: \(cseq)\r\n"
        for (k, v) in headers where k.lowercased() != "cseq" && k.lowercased() != "content-length" {
            msg += "\(k): \(v)\r\n"
        }
        if !body.isEmpty { msg += "Content-Length: \(body.count)\r\n" }
        msg += "\r\n"
        var out = Data(msg.utf8)
        out.append(body)
        connection.send(content: out, completion: .contentProcessed { [weak self] err in
            if let err { self?.fail(with: err) }
        })

        let signalled = entry.done.wait(timeout: .now() + timeout) == .success
        lock.lock()
        pending[cseq] = nil        // a response arriving after this is "late" and dropped
        let result = entry.result
        lock.unlock()

        guard signalled, let result else { throw RTSPError.timeout(method) }
        let response = try result.get()
        if ProcessInfo.processInfo.environment["AUDIOHUB_DEBUG"] != nil {
            log("RTSP \(method) → \(response.status) \(response.headers)")
        }
        guard response.status == 200 else { throw RTSPError.status(response.status, method) }
        return response
    }

    // MARK: Reading

    private func readLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data, !data.isEmpty { self.ingest(data) }
            if let err { self.fail(with: err); return }
            if done { self.fail(with: RTSPError.closed); return }
            self.readLoop()
        }
    }

    private func ingest(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var delivered: [(Pending, Response)] = []
        var late: [Response] = []
        var overflow = false
        while true {
            switch Self.parse(buffer) {
            case .incomplete:
                overflow = buffer.count > Self.maxResponseBytes
            case .invalid:
                overflow = true
            case .response(let r, let consumed):
                buffer.removeFirst(consumed)
                // Match strictly by CSeq. A response without one (RTSP requires it) cannot be
                // attributed to any request, so it is reported as unmatched, never guessed.
                if let key = r.cseq, let p = pending.removeValue(forKey: key) {
                    p.result = .success(r)
                    delivered.append((p, r))
                } else {
                    late.append(r)
                }
                continue
            }
            break
        }
        lock.unlock()
        for (p, _) in delivered { p.done.signal() }
        late.forEach { onLateResponse?($0) }
        if overflow { fail(with: RTSPError.protocolError("unparseable or oversized response")); connection.cancel() }
    }

    private func fail(with error: Error) {
        lock.lock()
        if closedError == nil { closedError = error }
        let waiting = Array(pending.values)
        pending.removeAll()
        for p in waiting { p.result = .failure(error) }
        lock.unlock()
        for p in waiting { p.done.signal() }
    }

    // MARK: Parsing

    enum ParseResult {
        case incomplete
        case invalid
        case response(Response, consumed: Int)
    }

    /// Body length from the Content-Length header values: none → 0 (no body); otherwise every
    /// value must be a plain decimal number (digits only: no sign, spaces or lists), within
    /// `maxResponseBytes`, and repeated headers must agree. Anything else → nil (malformed),
    /// never a guess: a wrong length would split the stream at the wrong place.
    static func contentLength(_ values: [String]) -> Int? {
        guard let first = values.first else { return 0 }
        guard values.allSatisfy({ $0 == first }),
              !first.isEmpty, first.utf8.count <= 10,
              first.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
              let n = Int(first), n <= maxResponseBytes
        else { return nil }
        return n
    }

    /// Parses one response from the start of `d`. Headers are text, the body may be binary.
    static func parse(_ d: Data) -> ParseResult {
        guard let end = d.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: d[d.startIndex ..< end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ")
        guard statusLine.count >= 2, statusLine[0].hasPrefix("RTSP/"), let code = Int(statusLine[1]) else { return .invalid }
        var headers: [String: String] = [:]
        var lengthValues: [String] = []
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { continue }
            let name = l[..<c].lowercased()
            let value = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length" { lengthValues.append(value) }
            headers[name] = value
        }
        guard let length = contentLength(lengthValues) else { return .invalid }
        let bodyStart = end.upperBound
        guard d.endIndex - bodyStart >= length else { return .incomplete }
        let body = d.subdata(in: bodyStart ..< bodyStart + length)
        return .response(Response(status: code, headers: headers, body: body),
                         consumed: bodyStart + length - d.startIndex)
    }
}

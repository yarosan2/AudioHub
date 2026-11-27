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
        print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
        exit(failures == 0 ? 0 : 1)
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

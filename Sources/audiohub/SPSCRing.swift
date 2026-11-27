import CAtomics
import Foundation

/// Lock-free single-producer / single-consumer ring buffer.
///
/// The real-time audio thread is the only producer, one network/worker queue the only
/// consumer. Neither side ever waits for the other or allocates memory: storage is
/// allocated up front, and the two positions are 64-bit counters that only grow
/// (they would take ~6 million years to wrap at 48 kHz). The producer publishes data with
/// a release store of `write`, the consumer acquires it; and vice versa for `read`.
///
/// When the buffer is full the producer drops the *new* samples (it must not move the
/// consumer's position) and counts them in `dropped`.
final class SPSCRing<Element> {
    let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Element>
    // Separate allocations keep the two hot counters on different cache lines.
    private let writePos: UnsafeMutablePointer<Int64>
    private let readPos: UnsafeMutablePointer<Int64>
    private let droppedCount: UnsafeMutablePointer<Int64>

    /// `minimumCapacity` is rounded up to a power of two.
    init(minimumCapacity: Int, zero: Element) {
        var c = 1
        while c < minimumCapacity { c <<= 1 }
        capacity = c
        mask = c - 1
        storage = .allocate(capacity: c)
        storage.initialize(repeating: zero, count: c)
        writePos = Self.counter(); readPos = Self.counter(); droppedCount = Self.counter()
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
        [writePos, readPos, droppedCount].forEach { UnsafeMutableRawPointer($0).deallocate() }
    }

    private static func counter() -> UnsafeMutablePointer<Int64> {
        let raw = UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 128)
        let p = raw.bindMemory(to: Int64.self, capacity: 1)
        p.initialize(to: 0)
        return p
    }

    /// Samples dropped because the consumer fell behind (producer-side count).
    var dropped: Int64 { ah_load_relaxed(droppedCount) }

    /// Elements ready for the consumer.
    var availableToRead: Int { Int(ah_load_acquire(writePos) - ah_load_relaxed(readPos)) }

    // MARK: Producer side (real-time safe)

    /// Copies up to `count` elements in; returns how many fit.
    @discardableResult
    func write(_ src: UnsafePointer<Element>, count: Int) -> Int {
        let w = ah_load_relaxed(writePos)            // only we write it
        let r = ah_load_acquire(readPos)             // consumer's progress
        let free = capacity - Int(w - r)
        let n = min(count, free)
        if n > 0 {
            let start = Int(w) & mask
            let first = min(n, capacity - start)
            (storage + start).update(from: src, count: first)
            if n > first { storage.update(from: src + first, count: n - first) }
            ah_store_release(writePos, w + Int64(n))  // publish after the copy
        }
        if n < count { ah_fetch_add_relaxed(droppedCount, Int64(count - n)) }
        return n
    }

    // MARK: Consumer side

    /// Copies up to `maxCount` elements out; returns how many were read.
    @discardableResult
    func read(into dst: UnsafeMutablePointer<Element>, maxCount: Int) -> Int {
        let r = ah_load_relaxed(readPos)             // only we write it
        let w = ah_load_acquire(writePos)            // producer's published data
        let n = min(maxCount, Int(w - r))
        if n > 0 {
            let start = Int(r) & mask
            let first = min(n, capacity - start)
            dst.update(from: storage + start, count: first)
            if n > first { (dst + first).update(from: storage, count: n - first) }
            ah_store_release(readPos, r + Int64(n))   // free the space after the copy
        }
        return n
    }

    /// Consumer-side: throw away everything currently buffered.
    func discardAll() {
        ah_store_release(readPos, ah_load_acquire(writePos))
    }
}

/// A Float shared between threads without tearing or locks (stored as its bit pattern).
final class AtomicFloat {
    private let p: UnsafeMutablePointer<Int64>
    init(_ v: Float) {
        p = .allocate(capacity: 1)
        p.initialize(to: Int64(v.bitPattern))
    }
    deinit { p.deallocate() }
    var value: Float {
        get { Float(bitPattern: UInt32(truncatingIfNeeded: ah_load_relaxed(p))) }
        set { ah_store_relaxed(p, Int64(newValue.bitPattern)) }
    }
}

import Foundation

/// Splits a stereo stream between two speakers: left channel (as mono) to one sink,
/// right channel to the other. A delay line holds back the side that plays earlier,
/// since Chromecast and AirPlay buffer different amounts. Optional calibration clicks
/// replace the audio so the two speakers can be lined up by ear.
///
/// Changing the delay never jumps the read position: the old and new positions are
/// crossfaded over `fadeSeconds`, so moving the slider does not click.
final class StereoSplitSink: AudioSink {
    let left: AudioSink
    let right: AudioSink

    /// Milliseconds the right speaker's feed is held back; negative holds back the left.
    /// Set from the UI, read on the real-time thread.
    var delayMs: Double {
        get { Double(delayBox.value) }
        set { delayBox.value = Float(newValue) }
    }
    /// Replace audio with a short click once per second on both sides.
    var clicks: Bool {
        get { clicksBox.value != 0 }
        set { clicksBox.value = newValue ? 1 : 0 }
    }

    static let fadeSeconds = 0.03

    private let delayBox = AtomicFloat(0)
    private let clicksBox = AtomicFloat(0)
    private let capacity = 48_000 * 21          // up to ~20 s of delay at 48 kHz
    private let maxBlock = 16_384
    private let lineL: UnsafeMutablePointer<Float>
    private let lineR: UnsafeMutablePointer<Float>
    private let outL: UnsafeMutablePointer<Float>
    private let outR: UnsafeMutablePointer<Float>
    private var write = 0
    private var clickPos = 0
    private var tapL = DelayTap(), tapR = DelayTap()

    init(left: AudioSink, right: AudioSink) {
        self.left = left
        self.right = right
        lineL = .allocate(capacity: capacity); lineL.initialize(repeating: 0, count: capacity)
        lineR = .allocate(capacity: capacity); lineR.initialize(repeating: 0, count: capacity)
        outL = .allocate(capacity: maxBlock * 2); outL.initialize(repeating: 0, count: maxBlock * 2)
        outR = .allocate(capacity: maxBlock * 2); outR.initialize(repeating: 0, count: maxBlock * 2)
    }

    deinit { [lineL, lineR, outL, outR].forEach { $0.deallocate() } }

    func consume(_ stereo: UnsafePointer<Float>, frames: Int, sampleRate: Double) {
        let n = min(frames, maxBlock)
        let rate = Int(sampleRate)
        let ms = Double(delayBox.value)
        let delay = min(Int(abs(ms) / 1000 * sampleRate), capacity - maxBlock - 1)
        let fadeLen = max(Int(Self.fadeSeconds * sampleRate), 1)
        tapL.retarget(ms < 0 ? delay : 0, fadeLength: fadeLen)
        tapR.retarget(ms > 0 ? delay : 0, fadeLength: fadeLen)
        let clicking = clicksBox.value != 0
        let clickLen = rate / 250             // 4 ms burst
        let halfPeriod = max(rate / 2_000, 1) // ~1 kHz square wave
        for f in 0 ..< n {
            var l = stereo[2 * f], r = stereo[2 * f + 1]
            if clicking {
                // A click every second; every 10th second a 300 ms beep instead, so the speakers
                // can't be lined up one whole click apart when the offset is several seconds.
                let p = clickPos % rate
                let isMarker = (clickPos / rate) % 10 == 0
                let len = isMarker ? rate * 3 / 10 : clickLen
                let c: Float = p < len ? ((p / halfPeriod) % 2 == 0 ? 0.5 : -0.5) : 0
                l = c; r = c
                clickPos += 1
            }
            lineL[write] = l
            lineR[write] = r
            let vl = tapL.next(from: lineL, write: write, capacity: capacity)
            let vr = tapR.next(from: lineR, write: write, capacity: capacity)
            outL[2 * f] = vl; outL[2 * f + 1] = vl
            outR[2 * f] = vr; outR[2 * f + 1] = vr
            write = (write + 1) % capacity
        }
        left.consume(outL, frames: n, sampleRate: sampleRate)
        right.consume(outR, frames: n, sampleRate: sampleRate)
    }
}

/// A read position `delay` samples behind the write position. When the delay changes it
/// crossfades from the old position to the new one instead of jumping. A change that
/// arrives mid-fade is picked up once the current fade finishes.
struct DelayTap {
    private(set) var delay = 0
    private var target = 0
    private var fadeFrom = 0
    private var fadePos = 0
    private var fadeLen = 0

    mutating func retarget(_ newDelay: Int, fadeLength: Int) {
        target = newDelay
        if fadeLen == 0, target != delay { startFade(fadeLength) }
        pendingFadeLength = fadeLength
    }
    private var pendingFadeLength = 1

    private mutating func startFade(_ length: Int) {
        fadeFrom = delay
        delay = target
        fadePos = 0
        fadeLen = length
    }

    mutating func next(from line: UnsafeMutablePointer<Float>, write: Int, capacity: Int) -> Float {
        let current = line[(write - delay + capacity) % capacity]
        guard fadeLen > 0 else { return current }
        let old = line[(write - fadeFrom + capacity) % capacity]
        let t = Float(fadePos) / Float(fadeLen)
        fadePos += 1
        if fadePos >= fadeLen {
            fadeLen = 0
            if target != delay { startFade(pendingFadeLength) }   // a newer change arrived mid-fade
        }
        return old * (1 - t) + current * t
    }
}

import Foundation

/// Splits a stereo stream between two speakers: left channel (as mono) to one sink,
/// right channel to the other. A delay line holds back the side that plays earlier,
/// since Chromecast and AirPlay buffer different amounts. Optional calibration clicks
/// replace the audio so the two speakers can be lined up by ear.
final class StereoSplitSink: AudioSink {
    let left: AudioSink
    let right: AudioSink

    /// Milliseconds the right speaker's feed is held back; negative holds back the left.
    var delayMs: Double = 0
    /// Replace audio with a short click once per second on both sides.
    var clicks = false
    /// Debug: loudest sample sent to each side since last read.
    private(set) var peakL: Float = 0, peakR: Float = 0

    private let capacity = 48_000 * 21          // up to ~20 s of delay at 48 kHz
    private let maxBlock = 16_384
    private let lineL: UnsafeMutablePointer<Float>
    private let lineR: UnsafeMutablePointer<Float>
    private let outL: UnsafeMutablePointer<Float>
    private let outR: UnsafeMutablePointer<Float>
    private var write = 0
    private var clickPos = 0

    init(left: AudioSink, right: AudioSink) {
        self.left = left
        self.right = right
        lineL = .allocate(capacity: capacity); lineL.initialize(repeating: 0, count: capacity)
        lineR = .allocate(capacity: capacity); lineR.initialize(repeating: 0, count: capacity)
        outL = .allocate(capacity: maxBlock * 2); outL.initialize(repeating: 0, count: maxBlock * 2)
        outR = .allocate(capacity: maxBlock * 2); outR.initialize(repeating: 0, count: maxBlock * 2)
    }

    deinit { [lineL, lineR, outL, outR].forEach { $0.deallocate() } }

    func takePeaks() -> (Float, Float) { defer { peakL = 0; peakR = 0 }; return (peakL, peakR) }

    func consume(_ stereo: UnsafePointer<Float>, frames: Int, sampleRate: Double) {
        let n = min(frames, maxBlock)
        let rate = Int(sampleRate)
        let delay = min(Int(abs(delayMs) / 1000 * sampleRate), capacity - maxBlock - 1)
        let dL = delayMs < 0 ? delay : 0
        let dR = delayMs > 0 ? delay : 0
        let clickLen = rate / 250             // 4 ms burst
        let halfPeriod = max(rate / 2_000, 1) // ~1 kHz square wave
        var pl: Float = 0, pr: Float = 0
        for f in 0 ..< n {
            var l = stereo[2 * f], r = stereo[2 * f + 1]
            if clicks {
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
            let vl = lineL[(write - dL + capacity) % capacity]
            let vr = lineR[(write - dR + capacity) % capacity]
            outL[2 * f] = vl; outL[2 * f + 1] = vl
            outR[2 * f] = vr; outR[2 * f + 1] = vr
            pl = max(pl, abs(vl)); pr = max(pr, abs(vr))
            write = (write + 1) % capacity
        }
        peakL = max(peakL, pl); peakR = max(peakR, pr)
        left.consume(outL, frames: n, sampleRate: sampleRate)
        right.consume(outR, frames: n, sampleRate: sampleRate)
    }
}

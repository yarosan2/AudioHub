import AudioToolbox
import CoreAudio
import Foundation

/// Receives captured audio as interleaved stereo Float32 on the real-time IO thread.
/// Implementations must not block.
protocol AudioSink: AnyObject {
    func consume(_ stereo: UnsafePointer<Float>, frames: Int, sampleRate: Double)
}

/// One routing rule: "the sound of these processes goes to that destination".
///
/// How it works: a Core Audio process tap captures the processes' output (and mutes it on
/// the device it was originally going to). A private aggregate device combines the tap
/// (as input) with a real output device (as output and clock). Our IO callback copies tap → output,
/// or hands the samples to a network sink.
final class Route {
    enum Destination {
        case device(OutputDevice)
        case sink(AudioSink, name: String)
    }

    let processes: [AudioProcess]
    let destination: Destination
    /// Set from the UI, read on the real-time thread.
    var gain: Float {
        get { gainBox.value }
        set { gainBox.value = newValue }
    }
    /// Written on the real-time thread, read by the UI.
    var peak: Float { peakBox.value }
    private let gainBox = AtomicFloat(1)
    private let peakBox = AtomicFloat(0)

    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var procID: AudioDeviceIOProcID?
    private var sampleRate: Double = 48_000
    private let scratchCapacity = 16_384
    private let scratch: UnsafeMutablePointer<Float>
    private let queue = DispatchQueue(label: "audiohub.route.io", qos: .userInteractive)
    private let debugLayout = ProcessInfo.processInfo.environment["AUDIOHUB_DEBUG"] != nil
    private var loggedLayout = false

    init(processes: [AudioProcess], destination: Destination) {
        self.processes = processes
        self.destination = destination
        scratch = .allocate(capacity: scratchCapacity * 2)
        scratch.initialize(repeating: 0, count: scratchCapacity * 2)
    }

    deinit {
        stop()
        scratch.deallocate()
    }

    var destinationName: String {
        switch destination {
        case .device(let d): return d.name
        case .sink(_, let name): return name
        }
    }

    func start() throws {
        // 1. Tap the processes, muting them at their original destination.
        let desc = CATapDescription(stereoMixdownOfProcesses: processes.map(\.objectID))
        desc.uuid = UUID()
        desc.name = "AudioHub tap"
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "create process tap")

        // 2. Aggregate device: real output device (clock + playback) + our tap (input).
        let clockDevice: OutputDevice
        switch destination {
        case .device(let d): clockDevice = d
        case .sink:
            if let q = ProcessInfo.processInfo.environment["AUDIOHUB_CLOCK"], let d = try OutputDevice.find(q) {
                clockDevice = d
            } else {
                clockDevice = try OutputDevice.defaultOutput()
            }
        }
        if ProcessInfo.processInfo.environment["AUDIOHUB_DEBUG"] != nil { log("clock device: \(clockDevice.name) \(clockDevice.uid)") }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioHub route",
            kAudioAggregateDeviceUIDKey: "audiohub.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: clockDevice.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockDevice.uid]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate device")
        sampleRate = (try? aggregateID.read(kAudioDevicePropertyNominalSampleRate, initial: Float64(48_000))) ?? 48_000

        // 3. IO callback.
        let sendsToDevice: Bool
        let sink: AudioSink?
        switch destination {
        case .device: sendsToDevice = true; sink = nil
        case .sink(let s, _): sendsToDevice = false; sink = s
        }
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [unowned self] _, input, _, output, _ in
            let frames = self.readTap(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)))
            let outList = UnsafeMutableAudioBufferListPointer(output)
            if sendsToDevice {
                self.writeOutput(outList, frames: frames)
            } else {
                for b in outList { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
                if frames > 0 { sink?.consume(self.scratch, frames: frames, sampleRate: self.sampleRate) }
            }
        }, "create IO proc")
        try check(AudioDeviceStart(aggregateID, procID), "start aggregate device")
    }

    func stop() {
        if let procID, aggregateID != .unknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != .unknown { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = .unknown }
        if tapID != .unknown { AudioHardwareDestroyProcessTap(tapID); tapID = .unknown }
    }

    /// Copies the tap's samples (always the last input stream(s) of the aggregate) into
    /// `scratch` as interleaved stereo, applying gain. Returns the frame count.
    private func readTap(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        if debugLayout, !loggedLayout {
            loggedLayout = true
            let desc = list.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B" }.joined(separator: ", ")
            DispatchQueue.main.async { log("input buffers: [\(desc)]") }
        }
        guard let last = list.last, let data = last.mData else { return 0 }
        let g = gain
        var p: Float = 0
        var frames = 0
        if last.mNumberChannels >= 2 {
            let ch = Int(last.mNumberChannels)
            frames = min(Int(last.mDataByteSize) / (4 * ch), scratchCapacity)
            let src = data.assumingMemoryBound(to: Float.self)
            for f in 0..<frames {
                let l = src[f * ch] * g, r = src[f * ch + 1] * g
                scratch[2 * f] = l; scratch[2 * f + 1] = r
                p = max(p, abs(l), abs(r))
            }
        } else {
            // Non-interleaved: last two mono buffers are L and R (or a single mono buffer).
            let rBuf = last
            let lBuf = list.count >= 2 ? list[list.count - 2] : last
            guard let ld = lBuf.mData, let rd = rBuf.mData else { return 0 }
            frames = min(Int(rBuf.mDataByteSize) / 4, Int(lBuf.mDataByteSize) / 4, scratchCapacity)
            let ls = ld.assumingMemoryBound(to: Float.self), rs = rd.assumingMemoryBound(to: Float.self)
            for f in 0..<frames {
                let l = ls[f] * g, r = rs[f] * g
                scratch[2 * f] = l; scratch[2 * f + 1] = r
                p = max(p, abs(l), abs(r))
            }
        }
        peakBox.value = max(p, peakBox.value * 0.9)
        return frames
    }

    /// Spreads stereo `scratch` over the device's output streams: channel 0 = L, 1 = R, rest silent.
    private func writeOutput(_ list: UnsafeMutableAudioBufferListPointer, frames: Int) {
        var channelBase = 0
        for b in list {
            guard let data = b.mData else { continue }
            let ch = Int(b.mNumberChannels)
            let dst = data.assumingMemoryBound(to: Float.self)
            let outFrames = Int(b.mDataByteSize) / (4 * max(ch, 1))
            for f in 0..<outFrames {
                for c in 0..<ch {
                    let global = channelBase + c
                    dst[f * ch + c] = (f < frames && global < 2) ? scratch[2 * f + global] : 0
                }
            }
            channelBase += ch
        }
    }
}

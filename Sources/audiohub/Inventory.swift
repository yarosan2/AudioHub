import AppKit
import CoreAudio
import Foundation

/// A process known to Core Audio (anything that has opened an audio client).
struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isPlaying: Bool

    /// Human friendly name: the owning app's name when this is a helper process.
    var displayName: String {
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName { return name }
        return bundleID.isEmpty ? "pid \(pid)" : bundleID
    }

    static func all() throws -> [AudioProcess] {
        let ids = try AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList, element: AudioObjectID.unknown)
        return ids.compactMap { id in
            guard let pid = try? id.read(kAudioProcessPropertyPID, initial: pid_t(-1)) else { return nil }
            let bundle = id.readString(kAudioProcessPropertyBundleID) ?? ""
            let running = (try? id.read(kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0
            return AudioProcess(objectID: id, pid: pid, bundleID: bundle, isPlaying: running != 0)
        }
    }

    /// Finds every audio process belonging to an app. Browsers and many players emit sound
    /// from helper processes (e.g. com.google.Chrome.helper), so we match by bundle-ID prefix,
    /// by app name, or by PID.
    static func matching(_ query: String) throws -> [AudioProcess] {
        let q = query.lowercased()
        let procs = try all()
        if let pid = pid_t(query) { return procs.filter { $0.pid == pid } }
        let exact = procs.filter { p in
            let b = p.bundleID.lowercased()
            return b == q || b.hasPrefix(q + ".") || p.displayName.lowercased() == q
        }
        if !exact.isEmpty { return exact }
        return procs.filter { $0.bundleID.lowercased().contains(q) || $0.displayName.lowercased().contains(q) }
    }
}

struct OutputDevice {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32
    let outputChannels: Int

    var transportLabel: String {
        switch transport {
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "Display"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        default: return "Other"
        }
    }

    static func all() throws -> [OutputDevice] {
        let ids = try AudioObjectID.system.readArray(kAudioHardwarePropertyDevices, element: AudioObjectID.unknown)
        return ids.compactMap { id in
            let outs = id.channelCount(scope: kAudioObjectPropertyScopeOutput)
            guard outs > 0, let uid = id.readString(kAudioDevicePropertyDeviceUID) else { return nil }
            let name = id.readString(kAudioObjectPropertyName) ?? uid
            let transport = (try? id.read(kAudioDevicePropertyTransportType, initial: UInt32(0))) ?? 0
            // Skip our own private aggregates.
            if uid.hasPrefix("audiohub.") { return nil }
            return OutputDevice(id: id, uid: uid, name: name, transport: transport, outputChannels: outs)
        }
    }

    static func defaultOutput() throws -> OutputDevice {
        let id = try AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID.unknown)
        guard let dev = try all().first(where: { $0.id == id }) else {
            throw CoreAudioError(status: -1, what: "default output lookup")
        }
        return dev
    }

    static func find(_ query: String) throws -> OutputDevice? {
        let q = query.lowercased()
        let devs = try all()
        return devs.first { $0.uid == query }
            ?? devs.first { $0.name.lowercased() == q }
            ?? devs.first { $0.name.lowercased().contains(q) }
    }
}

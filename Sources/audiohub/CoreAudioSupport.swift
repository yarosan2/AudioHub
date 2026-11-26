import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let what: String
    var description: String {
        let be = UInt32(bitPattern: status).bigEndian
        let fourCC = withUnsafeBytes(of: be) { raw -> String in
            let s = String(bytes: raw, encoding: .ascii) ?? ""
            return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " } ? "'\(s)'" : ""
        }
        return "\(what) failed: OSStatus \(status) \(fourCC)"
    }
}

@inline(__always)
func check(_ status: OSStatus, _ what: @autoclosure () -> String) throws {
    if status != noErr { throw CoreAudioError(status: status, what: what()) }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    private func address(_ sel: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    func has(_ sel: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var addr = address(sel, scope)
        return AudioObjectHasProperty(self, &addr)
    }

    func read<T>(_ sel: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 initial: T) throws -> T {
        var addr = address(sel, scope)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        try check(AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &value), "read \(sel)")
        return value
    }

    func readQualified<T, Q>(_ sel: AudioObjectPropertySelector, qualifier: Q, initial: T) throws -> T {
        var addr = address(sel, kAudioObjectPropertyScopeGlobal)
        var q = qualifier
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        try check(AudioObjectGetPropertyData(self, &addr, UInt32(MemoryLayout<Q>.size), &q, &size, &value), "read \(sel)")
        return value
    }

    func readArray<T>(_ sel: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                      element: T) throws -> [T] {
        var addr = address(sel, scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size), "size \(sel)")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var values = [T](repeating: element, count: count)
        try check(AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &values), "read \(sel)")
        return Array(values.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    func readString(_ sel: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var addr = address(sel, scope)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let err = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(self, &addr, 0, nil, &size, $0)
        }
        guard err == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    /// Number of channels this device exposes in the given scope.
    func channelCount(scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(self, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

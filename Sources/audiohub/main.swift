import CryptoKit
import Foundation

func usage() -> Never {
    print("""
    audiohub — per-app audio router

      audiohub list                      audio apps and local output devices
      audiohub speakers                  Chromecast and AirPlay speakers on the network
      audiohub route <app>=<dest> ...    route one or more apps; Ctrl+C to stop

        app:  name, bundle id or pid      (see `audiohub list`)
        dest: local device name/uid       e.g. "Rear Analog"
              cast:<speaker name>         Chromecast, e.g. cast:Bedroom
              airplay:<speaker name>      AirPlay,    e.g. airplay:Kitchen

      example: audiohub route Spotify=cast:Bedroom Music=airplay:Kitchen
    """)
    exit(1)
}

func list() throws {
    print("Apps with audio (▶ = playing now):")
    for p in try AudioProcess.all().sorted(by: { $0.displayName < $1.displayName }) {
        print("  \(p.isPlaying ? "▶" : " ") \(p.displayName.padding(toLength: 28, withPad: " ", startingAt: 0)) pid \(p.pid)  \(p.bundleID)")
    }
    print("\nOutput devices (* = default):")
    let def = try? OutputDevice.defaultOutput()
    for d in try OutputDevice.all() {
        print("  \(d.id == def?.id ? "*" : " ") [\(d.transportLabel)] \(d.name)  (\(d.outputChannels) ch)  uid=\(d.uid)")
    }
}

final class Running {
    var routes: [Route] = []
    var casts: [CastSession] = []
    var servers: [PCMStreamServer] = []
    var airplays: [AirPlaySession] = []
    func stopAll() {
        routes.forEach { $0.stop() }
        casts.forEach { $0.stop() }
        airplays.forEach { $0.stop() }
        servers.forEach { $0.stop() }
    }
}
let running = Running()

/// Lets capture start before the network destination is known.
final class SinkRelay: AudioSink {
    var target: AudioSink?
    func consume(_ stereo: UnsafePointer<Float>, frames: Int, sampleRate: Double) {
        target?.consume(stereo, frames: frames, sampleRate: sampleRate)
    }
}

func buildRoute(app: String, dest: String) throws {
    let procs = try AudioProcess.matching(app)
    guard !procs.isEmpty else {
        throw CoreAudioError(status: -1, what: "No audio process matches '\(app)' — start playback, then check `audiohub list`. Lookup")
    }
    let appName = procs.first!.displayName
    if dest.lowercased().hasPrefix("airplay:") {
        let q = String(dest.dropFirst(8)).lowercased()
        // Capture first (silences the app on the monitor at once); the speaker is attached after discovery.
        let relay = SinkRelay()
        let route = Route(processes: procs, destination: .sink(relay, name: "airplay:\(q)"))
        try route.start()
        let devices = AirPlayDiscovery.scan()
        guard let dev = devices.first(where: { $0.name.lowercased() == q }) ?? devices.first(where: { $0.name.lowercased().contains(q) }) else {
            route.stop()
            throw CoreAudioError(status: -1, what: "No AirPlay speaker matches '\(q)' (found: \(devices.map(\.name))). Lookup")
        }
        let session = AirPlaySession(device: dev)
        session.volumeDB = ProcessInfo.processInfo.environment["AUDIOHUB_VOLUME_DB"].flatMap(Double.init) ?? -12
        session.onStatus = { log("[\(dev.name)] \($0)") }
        relay.target = session
        session.start()
        running.routes.append(route); running.airplays.append(session)
        print("\(appName) → AirPlay \(dev.name)")
    } else if dest.lowercased().hasPrefix("cast:") {
        let q = String(dest.dropFirst(5)).lowercased()
        // Capture first so the app goes quiet on its original output right away.
        let server = try PCMStreamServer()
        let route = Route(processes: procs, destination: .sink(server, name: "cast:\(q)"))
        try route.start()
        let devices = CastDiscovery.scan()
        guard let dev = devices.first(where: { $0.name.lowercased() == q }) ?? devices.first(where: { $0.name.lowercased().contains(q) }) else {
            route.stop()
            throw CoreAudioError(status: -1, what: "No Chromecast matches '\(q)' (found: \(devices.map(\.name))). Lookup")
        }
        guard server.waitForAudioFormat(timeout: 5) else {
            route.stop()
            throw CoreAudioError(status: -1, what: "No audio from '\(appName)' within 5 s (is it playing? is audio capture allowed?). Capture")
        }
        let session = CastSession(device: dev)
        session.onStatus = { log("[\(dev.name)] \($0)") }
        let port = server.port, path = server.path
        session.play { ip, speaker in
            server.allow(client: speaker)
            return "http://\(ip):\(port)\(path)"
        }
        running.routes.append(route); running.servers.append(server); running.casts.append(session)
        print("\(appName) → Chromecast \(dev.name) (\(dev.model)), stream on port \(port)")
    } else {
        guard let dev = try OutputDevice.find(dest) else {
            throw CoreAudioError(status: -1, what: "No output device matches '\(dest)'. Lookup")
        }
        let route = Route(processes: procs, destination: .device(dev))
        try route.start()
        running.routes.append(route)
        print("\(appName) → \(dev.name)")
    }
}

func runForever(seconds: Double?) -> Never {
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        s.setEventHandler { running.stopAll(); print("\nstopped"); exit(0) }
        s.resume()
        _sources.append(s)
    }
    let started = Date()
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: 0.25)
    timer.setEventHandler {
        let line = running.routes.map { r in
            let bars = String(repeating: "█", count: Int(min(r.peak, 1) * 10)).padding(toLength: 10, withPad: "·", startingAt: 0)
            return "\(r.processes.first?.displayName ?? "?")→\(r.destinationName) \(bars)"
        }.joined(separator: "  ")
        FileHandle.standardError.write("\r\(line)".data(using: .utf8)!)
        if let seconds, Date().timeIntervalSince(started) > seconds { running.stopAll(); print(""); exit(0) }
    }
    timer.resume()
    _sources.append(timer)
    dispatchMain()
}
var _sources: [DispatchSourceProtocol] = []

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case "selftest":
        SelfTest.run(arguments: Array(args.dropFirst()))
    case "update-keygen" where args.count > 1 && args[1] == "--rotate":
        // Step 1 of a key rotation: create the successor key next to the active one.
        guard SigningKeyStore.load() != nil else { print("No active key; run update-keygen first."); exit(1) }
        let nextKey: Curve25519.Signing.PrivateKey
        if let k = SigningKeyStore.load(SigningKeyStore.next) {
            nextKey = k
            print("A next key already exists.")
        } else {
            nextKey = Curve25519.Signing.PrivateKey()
            try SigningKeyStore.save(nextKey, as: SigningKeyStore.next)
            print("Created the next signing key in your login keychain.")
        }
        print("Put this public key into Info.plist as AHUpdatePublicKey for the transition release:")
        print(SigningKeyStore.publicKey(of: nextKey))
        print("That release is still signed with the current key, so installed copies accept it.")
        print("After it is published: audiohub update-keygen --finish-rotation")
    case "update-keygen" where args.count > 1 && args[1] == "--finish-rotation":
        // Step 2: the next key becomes the active one; the old key is deleted.
        guard let nextKey = SigningKeyStore.load(SigningKeyStore.next) else { print("No next key to promote."); exit(1) }
        try SigningKeyStore.delete(SigningKeyStore.active)
        try SigningKeyStore.save(nextKey, as: SigningKeyStore.active)
        guard SigningKeyStore.load().map(SigningKeyStore.publicKey) == SigningKeyStore.publicKey(of: nextKey) else {
            print("Could not verify the promoted key; the next key is kept."); exit(1)
        }
        try SigningKeyStore.delete(SigningKeyStore.next)
        print("Rotation finished. Active public key: \(SigningKeyStore.publicKey(of: nextKey))")
        print("The old key was deleted. Back up the new one from a separate Terminal window:")
        print("  security find-generic-password -s \"\(SigningKeyStore.service)\" -a \(SigningKeyStore.active) -w")
    case "update-keygen":
        // Creates the release signing key (once) and prints the public key for Info.plist.
        if let existing = SigningKeyStore.load() {
            print("A signing key already exists in the keychain. Public key:")
            print(existing.publicKey.rawRepresentation.base64EncodedString())
        } else {
            let key = Curve25519.Signing.PrivateKey()
            try SigningKeyStore.save(key)
            print("Created a new signing key in your login keychain (\"\(SigningKeyStore.service)\").")
            print("Put this public key into Info.plist as AHUpdatePublicKey:")
            print(key.publicKey.rawRepresentation.base64EncodedString())
            print("Back up the private key (64 hex characters) into a password manager:")
            print("  security find-generic-password -s \"\(SigningKeyStore.service)\" -w")
        }
    case "sign-update":
        guard args.count == 2 else { print("usage: audiohub sign-update <AudioHub-x.y.z.zip>"); exit(1) }
        guard let key = SigningKeyStore.load() else { print("No signing key; run update-keygen first."); exit(1) }
        let url = URL(fileURLWithPath: args[1])
        let data = try Data(contentsOf: url)
        let sig = try UpdateSignature.sign(data, with: key)
        let activePub = SigningKeyStore.publicKey(of: key)
        let nextPub = SigningKeyStore.load(SigningKeyStore.next).map(SigningKeyStore.publicKey)
        guard UpdateSignature.verify(data, signature: sig, publicKey: activePub) else { print("Self-check failed."); exit(1) }
        switch SigningKeyStore.plan(embedded: UpdateConfig.publicKey ?? "", activeKey: activePub, nextKey: nextPub) {
        case .normal:
            print("Signed with the current key (matches AHUpdatePublicKey).")
        case .transition:
            print("TRANSITION RELEASE: signed with the current key, ships the next key in Info.plist.")
            print("After publishing it, run: audiohub update-keygen --finish-rotation")
        case .mismatch:
            print("AHUpdatePublicKey in this build is neither the current nor the next key; installed copies")
            print("could never verify releases after it. Not signing.")
            exit(1)
        }
        try (sig + "\n").write(to: url.appendingPathExtension("sig"), atomically: true, encoding: .utf8)
        print("wrote \(url.lastPathComponent).sig")
    case "check-update":
        let sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            let m = UpdateManager()
            await m.check(userInitiated: true)
            print("installed: \(AppVersion.current), release build: \(UpdateConfig.isReleaseBuild), in-app install: \(m.canInstallInApp)")
            print("result: \(m.state)")
            sem.signal()
        }
        while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    case "list":
        try list()
    case "speakers", "cast-list":
        let group = DispatchGroup()
        var casts: [CastDevice] = [], airplays: [AirPlayDevice] = []
        DispatchQueue.global().async(group: group) { casts = CastDiscovery.scan() }
        DispatchQueue.global().async(group: group) { airplays = AirPlayDiscovery.scan() }
        group.wait()
        print("Chromecast:"); casts.forEach { print("  cast:\($0.name)  [\($0.model)]") }
        print("AirPlay:"); airplays.forEach { print("  airplay:\($0.name)  [\($0.txt["am"] ?? "")]") }
    case "route":
        var rest = Array(args.dropFirst())
        var seconds: Double?
        if let i = rest.firstIndex(of: "--seconds"), i + 1 < rest.count { seconds = Double(rest[i + 1]); rest.removeSubrange(i...i + 1) }
        // Legacy form: route <app> <dest>
        if rest.count == 2, !rest[0].contains("=") { rest = ["\(rest[0])=\(rest[1])"] }
        guard !rest.isEmpty else { usage() }
        for pair in rest {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { usage() }
            try buildRoute(app: parts[0], dest: parts[1])
        }
        print("Routing active. Ctrl+C to stop.")
        runForever(seconds: seconds)
    case nil:
        AudioHubApp.main()   // no arguments → menu-bar app
    case let a? where a.hasPrefix("-"):
        AudioHubApp.main()   // Finder/launchd may pass -psn_… or -NS… flags
    default:
        usage()
    }
} catch {
    running.stopAll()
    print("Error: \(error)")
    exit(1)
}

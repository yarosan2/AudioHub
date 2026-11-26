import AppKit
import CoreAudio
import Foundation

/// One app as the user sees it: the app plus all its audio helper processes
/// (Chrome tabs, Electron renderers, Safari's shared WebKit audio process…).
struct AppGroup: Identifiable {
    let id: String            // owning app's bundle id
    let name: String
    let icon: NSImage?
    let processes: [AudioProcess]
    var isPlaying: Bool { processes.contains { $0.isPlaying } }
    var processIDs: Set<AudioObjectID> { Set(processes.map(\.objectID)) }

    static func current() -> [AppGroup] {
        let procs = (try? AudioProcess.all()) ?? []
        // Dock apps and menu-bar apps (e.g. Radiola), but not background daemons.
        let regular = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy != .prohibited && $0.bundleIdentifier != nil && $0.processIdentifier != getpid()
        }
        func owner(of p: AudioProcess) -> NSRunningApplication? {
            if let a = regular.first(where: { $0.processIdentifier == p.pid }) { return a }
            if p.bundleID == "com.apple.WebKit.GPU" {
                return regular.first { $0.bundleIdentifier == "com.apple.Safari" }
            }
            // Helper bundle ids extend the app's: com.google.Chrome.helper → com.google.Chrome
            return regular
                .filter { p.bundleID.hasPrefix($0.bundleIdentifier! + ".") }
                .max { $0.bundleIdentifier!.count < $1.bundleIdentifier!.count }
        }
        var byApp: [String: (name: String, icon: NSImage?, procs: [AudioProcess])] = [:]
        for p in procs where p.pid != getpid() {
            if let app = owner(of: p), let id = app.bundleIdentifier {
                byApp[id, default: (app.localizedName ?? id, app.icon, [])].procs.append(p)
            } else if p.isPlaying {
                // Something without a UI is playing right now (a CLI player, a daemon): show it too.
                let id = p.bundleID.isEmpty ? "pid:\(p.pid)" : p.bundleID
                let icon = NSRunningApplication(processIdentifier: p.pid)?.icon
                byApp[id, default: (p.displayName, icon, [])].procs.append(p)
            }
        }
        return byApp.map { id, v in
            AppGroup(id: id, name: v.name, icon: v.icon, processes: v.procs)
        }
        .sorted { ($0.isPlaying ? 0 : 1, $0.name) < ($1.isPlaying ? 0 : 1, $1.name) }
    }
}

/// Where an app's sound can go. Encoded as a string so it can be stored:
/// "" = leave alone, "device:<uid>", "cast:<name>", "airplay:<name>".
struct DestinationOption: Identifiable, Hashable {
    let id: String
    let name: String
}

@MainActor
final class Engine: ObservableObject {
    @Published private(set) var apps: [AppGroup] = []
    @Published private(set) var localOptions: [DestinationOption] = []
    @Published private(set) var castOptions: [DestinationOption] = []
    @Published private(set) var airplayOptions: [DestinationOption] = []
    @Published private(set) var scanning = false
    @Published private(set) var status: [String: String] = [:]
    @Published var assignments: [String: String] {
        didSet { UserDefaults.standard.set(assignments, forKey: "assignments") }
    }
    /// Per-app volume 0…1. For speakers on the network it is the speaker's own volume;
    /// for outputs of this Mac it scales the signal.
    @Published private(set) var gains: [String: Float] {
        didSet { UserDefaults.standard.set(gains.mapValues(Double.init), forKey: "gains") }
    }

    private var lastUserVolumeChange: [String: Date] = [:]

    // MARK: Stereo pair

    static let pairID = "pair"
    static let pairLeftKey = "pair.L", pairRightKey = "pair.R"

    /// Speaker for the left / right channel ("cast:…" or "airplay:…").
    @Published var pairLeft: String { didSet { pairSpeakersChanged() } }
    @Published var pairRight: String { didSet { pairSpeakersChanged() } }
    /// How long the right speaker's feed is held back (negative: the left one), in ms.
    @Published var pairDelayMs: Double {
        didSet {
            UserDefaults.standard.set(pairDelayMs, forKey: "pairDelayMs")
            splitter?.delayMs = pairDelayMs
        }
    }
    @Published var pairClicks = false { didSet { splitter?.clicks = pairClicks } }

    /// UI language code, "" = system. Changing it re-renders the menu in the new language.
    @Published var language: String = Language.selected {
        didSet { Language.selected = language }
    }
    @Published private(set) var pairStatusL: String?
    @Published private(set) var pairStatusR: String?
    var pairIsActive: Bool { splitter != nil }
    private var splitter: StereoSplitSink?
    private var pairVolumeSetters: [String: (Double) -> Void] = [:]

    func setPairVolume(_ value: Float, side key: String) {
        gains[key] = value
        lastUserVolumeChange[key] = Date()
        pairVolumeSetters[key]?(Double(value * masterLevel))
    }

    private func pairSpeakersChanged() {
        UserDefaults.standard.set(pairLeft, forKey: "pairLeft")
        UserDefaults.standard.set(pairRight, forKey: "pairRight")
        // Reconnect whichever app currently plays through the pair.
        for (id, d) in assignments where d == Self.pairID {
            active[id]?.stop()
            active[id] = nil
            apply(id)
        }
    }

    // MARK: Master volume

    /// Scales every route AudioHub drives, on top of the per-app / per-speaker levels.
    @Published private(set) var master: Float {
        didSet { UserDefaults.standard.set(Double(master), forKey: "master") }
    }
    @Published private(set) var muted = false
    var masterLevel: Float { muted ? 0 : master }

    func setMaster(_ value: Float) {
        master = value
        if value > 0 { muted = false }
        applyMaster()
    }

    func toggleMute() {
        muted.toggle()
        applyMaster()
    }

    private func applyMaster() {
        let m = masterLevel
        let now = Date()
        for (id, a) in active {
            if a.destination == Self.pairID {
                for (key, set) in pairVolumeSetters {
                    lastUserVolumeChange[key] = now
                    set(Double((gains[key] ?? 0.6) * m))
                }
            } else if let set = a.setVolume {
                lastUserVolumeChange[id] = now
                set(Double((gains[id] ?? 1) * m))
            } else {
                a.route?.gain = (gains[id] ?? 1) * m
            }
        }
    }

    func setGain(_ value: Float, for appID: String) {
        gains[appID] = value
        lastUserVolumeChange[appID] = Date()
        guard let a = active[appID] else { return }
        if let setVolume = a.setVolume { setVolume(Double(value * masterLevel)) } else { a.route?.gain = value * masterLevel }
    }

    func isNetworkRoute(_ appID: String) -> Bool {
        let d = assignments[appID] ?? ""
        return d.hasPrefix("cast:") || d.hasPrefix("airplay:")
    }

    var activeCount: Int { active.count }

    private var casts: [CastDevice] = []
    private var airplays: [AirPlayDevice] = []
    private var active: [String: ActiveRoute] = [:]
    private var poll: Timer?

    /// A running route. The network session outlives the tap: when an app spawns a new
    /// helper process only the tap is rebuilt and the speaker keeps playing.
    private final class ActiveRoute {
        let destination: String
        var route: Route?
        var processIDs: Set<AudioObjectID> = []
        let sink: AudioSink?
        let device: OutputDevice?
        let stopNetwork: () -> Void
        /// Set for network speakers: controls the speaker's volume instead of the signal.
        var setVolume: ((Double) -> Void)?
        init(destination: String, sink: AudioSink?, device: OutputDevice?, stopNetwork: @escaping () -> Void) {
            self.destination = destination; self.sink = sink; self.device = device; self.stopNetwork = stopNetwork
        }
        func stop() { route?.stop(); route = nil; stopNetwork() }
    }

    init() {
        assignments = UserDefaults.standard.dictionary(forKey: "assignments") as? [String: String] ?? [:]
        gains = (UserDefaults.standard.dictionary(forKey: "gains") as? [String: Double] ?? [:]).mapValues(Float.init)
        master = (UserDefaults.standard.object(forKey: "master") as? Double).map(Float.init) ?? 1
        pairLeft = UserDefaults.standard.string(forKey: "pairLeft") ?? ""
        pairRight = UserDefaults.standard.string(forKey: "pairRight") ?? ""
        pairDelayMs = UserDefaults.standard.double(forKey: "pairDelayMs")
        refresh()
        rescan()
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rescan() }
        }
    }

    // MARK: User actions

    func setDestination(_ dest: String, for appID: String) {
        // The pair's two speakers can serve only one app at a time.
        if dest == Self.pairID {
            for (id, d) in assignments where d == Self.pairID && id != appID {
                assignments[id] = nil
                apply(id)
            }
        }
        assignments[appID] = dest.isEmpty ? nil : dest
        status[appID] = nil
        apply(appID)
    }

    func rescan() {
        guard !scanning else { return }
        scanning = true
        Task.detached {
            async let c = CastDiscovery.scan()
            async let a = AirPlayDiscovery.scan()
            let (casts, airplays) = await (c, a)
            await MainActor.run {
                self.casts = casts
                self.airplays = airplays
                self.castOptions = casts.map { DestinationOption(id: "cast:\($0.name)", name: $0.name) }
                self.airplayOptions = airplays.map { DestinationOption(id: "airplay:\($0.name)", name: $0.name) }
                self.scanning = false
                self.assignments.keys.forEach(self.apply)
            }
        }
    }

    func stopAll() {
        active.values.forEach { $0.stop() }
        active.removeAll()
    }

    // MARK: Routing

    private func refresh() {
        apps = AppGroup.current()
        let devices = (try? OutputDevice.all()) ?? []
        let def = try? OutputDevice.defaultOutput()
        // Several outputs can share a name (HDMI ports), so add the port suffix.
        let dupes = Dictionary(grouping: devices, by: \.name).filter { $0.value.count > 1 }.keys
        localOptions = devices.map { d in
            var n = d.name
            if dupes.contains(d.name) { n += " · " + (d.uid.split(separator: "/").last.map(String.init) ?? d.uid) }
            if d.id == def?.id { n += L(" (default)") }
            return DestinationOption(id: "device:\(d.uid)", name: n)
        }
        Set(assignments.keys).union(active.keys).forEach(apply)
    }

    /// Brings the running state for one app in line with its assignment.
    private func apply(_ appID: String) {
        let wanted = assignments[appID] ?? ""
        let group = apps.first { $0.id == appID }

        if let a = active[appID], a.destination != wanted || group == nil {
            a.stop()
            active[appID] = nil
        }
        guard !wanted.isEmpty, let group else { return }

        if let a = active[appID] {
            if a.processIDs != group.processIDs { restartTap(a, group: group, appID: appID) }
            return
        }
        do {
            let a = try makeRoute(wanted, appID: appID)
            active[appID] = a
            restartTap(a, group: group, appID: appID)
        } catch {
            status[appID] = "\(error)"
        }
    }

    private func restartTap(_ a: ActiveRoute, group: AppGroup, appID: String) {
        a.route?.stop()
        let destination: Route.Destination
        if let d = a.device { destination = .device(d) }
        else if let s = a.sink { destination = .sink(s, name: a.destination) }
        else { return }
        let r = Route(processes: group.processes, destination: destination)
        r.gain = (a.setVolume == nil && a.destination != Self.pairID) ? (gains[appID] ?? 1) * masterLevel : 1
        do {
            try r.start()
            a.route = r
            a.processIDs = group.processIDs
        } catch {
            status[appID] = L("Could not capture audio: %@", "\(error)")
        }
    }

    private func makeRoute(_ dest: String, appID: String) throws -> ActiveRoute {
        let report: (String) -> Void = { [weak self] s in
            Task { @MainActor in self?.status[appID] = s }
        }
        if dest.hasPrefix("device:") {
            let uid = String(dest.dropFirst(7))
            guard let d = try OutputDevice.all().first(where: { $0.uid == uid }) else {
                throw UserError(L("Output device is not connected."))
            }
            return ActiveRoute(destination: dest, sink: nil, device: d, stopNetwork: {})
        }
        if dest == Self.pairID {
            guard !pairLeft.isEmpty, !pairRight.isEmpty, pairLeft != pairRight else {
                throw UserError(L("Choose two different speakers for the stereo pair."))
            }
            let l = try makeNetworkSink(pairLeft, volumeKey: Self.pairLeftKey) { [weak self] s in
                Task { @MainActor in self?.pairStatusL = s }
            }
            let r: NetworkSink
            do {
                r = try makeNetworkSink(pairRight, volumeKey: Self.pairRightKey) { [weak self] s in
                    Task { @MainActor in self?.pairStatusR = s }
                }
            } catch { l.stop(); throw error }
            let split = StereoSplitSink(left: l.sink, right: r.sink)
            split.delayMs = pairDelayMs
            split.clicks = pairClicks
            splitter = split
            pairVolumeSetters = [Self.pairLeftKey: l.setVolume, Self.pairRightKey: r.setVolume]
            report(L("stereo pair: L — %@, R — %@", Self.displayName(pairLeft), Self.displayName(pairRight)))
            return ActiveRoute(destination: dest, sink: split, device: nil) { [weak self] in
                l.stop(); r.stop()
                Task { @MainActor in
                    guard let self else { return }
                    if self.splitter === split { self.splitter = nil; self.pairVolumeSetters = [:] }
                    self.pairStatusL = nil; self.pairStatusR = nil
                }
            }
        }
        let n = try makeNetworkSink(dest, volumeKey: appID, report: report)
        let a = ActiveRoute(destination: dest, sink: n.sink, device: nil, stopNetwork: n.stop)
        a.setVolume = n.setVolume
        return a
    }

    private struct NetworkSink {
        let sink: AudioSink
        let stop: () -> Void
        let setVolume: (Double) -> Void
    }

    /// Connects to a Chromecast or AirPlay speaker. `volumeKey` is where its volume is kept in `gains`.
    private func makeNetworkSink(_ dest: String, volumeKey: String,
                                 report: @escaping (String) -> Void) throws -> NetworkSink {
        if dest.hasPrefix("cast:") {
            let name = String(dest.dropFirst(5))
            guard let cast = casts.first(where: { $0.name == name }) else {
                throw UserError(L("Speaker “%@” was not found on the network.", name))
            }
            let server = try PCMStreamServer()
            let session = CastSession(device: cast)
            session.onStatus = { s in
                if s.hasPrefix("player: PLAYING") { report(L("▶ playing on “%@”", name)) }
                else if s.hasPrefix("player: BUFFERING") { report(L("“%@” is buffering…", name)) }
                else if s.contains("fail") || s.contains("error") || s.contains("could not") { report(s) }
            }
            // Follow the speaker's own volume (including buttons on the speaker / Google Home app).
            session.onVolume = { [weak self] level in
                Task { @MainActor in
                    guard let self else { return }
                    // Ignore echoes of our own changes while the slider is being dragged.
                    if let t = self.lastUserVolumeChange[volumeKey], Date().timeIntervalSince(t) < 1.5 { return }
                    // The speaker reports its real volume = personal level × master.
                    guard self.masterLevel > 0.01 else { return }
                    self.gains[volumeKey] = min(1, Float(level) / self.masterLevel)
                }
            }
            report(L("connecting to “%@”…", name))
            DispatchQueue.global().async {
                guard server.waitForAudioFormat(timeout: 10) else { report(L("no audio from the app")); return }
                session.play { ip in "http://\(ip):\(server.port)\(server.path)" }
            }
            return NetworkSink(sink: server, stop: { [server] in
                _ = server  // keep the HTTP server alive as long as the route
                DispatchQueue.global().async { session.stop() }
            }, setVolume: { session.setVolume($0) })
        }
        if dest.hasPrefix("airplay:") {
            let name = String(dest.dropFirst(8))
            guard let dev = airplays.first(where: { $0.name == name }) else {
                throw UserError(L("Speaker “%@” was not found on the network.", name))
            }
            let session = AirPlaySession(device: dev)
            // AirPlay speakers don't report volume, so start from the remembered level (default 60 %).
            let level = Double(gains[volumeKey] ?? 0.6)
            gains[volumeKey] = Float(level)
            let effective = level * Double(masterLevel)
            session.volumeDB = effective <= 0.001 ? -144 : -30 + 30 * effective
            session.onStatus = { s in
                if s.hasPrefix("streaming") { report(L("▶ playing on “%@” (≈2 s delay)", name)) }
                else if s.contains("fail") || s.contains("could not") { report(s) }
            }
            report(L("connecting to “%@”…", name))
            session.start()
            return NetworkSink(sink: session, stop: { DispatchQueue.global().async { session.stop() } },
                               setVolume: { session.setVolume($0) })
        }
        throw UserError(L("Unknown destination %@.", dest))
    }

    static func displayName(_ dest: String) -> String {
        dest.split(separator: ":", maxSplits: 1).last.map(String.init) ?? dest
    }
}

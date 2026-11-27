import AppKit
import SwiftUI

/// Menu-bar app. Launched with no CLI arguments (e.g. from Finder or at login).
struct AudioHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var engine = Engine()
    @StateObject private var updates = UpdateManager()

    var body: some Scene {
        MenuBarExtra {
            MenuView(engine: engine, updates: updates)
                .onAppear { delegate.engine = engine }
        } label: {
            Image(systemName: engine.activeCount > 0 ? "hifispeaker.2.fill" : "hifispeaker.2")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var engine: Engine?
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { engine?.stopAll() }
    }
}

struct MenuView: View {
    @ObservedObject var engine: Engine
    @ObservedObject var updates: UpdateManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("AudioHub").font(.headline)
                Spacer()
                if engine.scanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button { engine.rescan() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help(L("Search the network for speakers again"))
                }
            }
            UpdateBanner(updates: updates, language: engine.language)
            MasterVolumeRow(engine: engine)
            Divider()
            if engine.apps.isEmpty {
                Text(L("No apps are playing audio.\nStart playback and the app will appear here."))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(engine.apps) { app in AppRow(app: app, engine: engine) }
                    }
                }
                // A ScrollView has no natural height inside a menu-bar window: size it to
                // its content, capped so long lists scroll.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: 420)
            }
            Divider()
            DisclosureGroup(L("Stereo pair")) { StereoPairPanel(engine: engine) }
                .font(.callout)
            Divider()
            HStack {
                Text(speakerSummary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                UpdateMenu(updates: updates, language: engine.language)
                LanguageMenu(engine: engine)
                Button(L("Quit")) { NSApp.terminate(nil) }.buttonStyle(.borderless)
            }
        }
        .padding(12)
        .frame(width: 380)
    }

    private var speakerSummary: String {
        let c = engine.castOptions.count, a = engine.airplayOptions.count
        return L("On the network: Chromecast %ld, AirPlay %ld", c, a)
    }
}

struct AppRow: View {
    let app: AppGroup
    @ObservedObject var engine: Engine

    private var destination: Binding<String> {
        Binding(get: { engine.assignments[app.id] ?? "" },
                set: { engine.setDestination($0, for: app.id) })
    }
    private var gain: Binding<Double> {
        Binding(get: { Double(engine.gains[app.id] ?? 1) },
                set: { engine.setGain(Float($0), for: app.id) })
    }
    private var isRouted: Bool { !(engine.assignments[app.id] ?? "").isEmpty }
    private var isPair: Bool { engine.assignments[app.id] == Engine.pairID }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(app.name).lineLimit(1)
                        if app.isPlaying {
                            Image(systemName: "waveform").font(.caption2).foregroundStyle(.green)
                        }
                    }
                }
                Spacer(minLength: 6)
                Picker("", selection: destination) {
                    Text(L("Unchanged")).tag("")
                    Section(L("This Mac")) {
                        ForEach(engine.localOptions) { Text($0.name).tag($0.id) }
                    }
                    if !engine.castOptions.isEmpty {
                        Section("Chromecast") {
                            ForEach(engine.castOptions) { Text($0.name).tag($0.id) }
                        }
                    }
                    if !engine.airplayOptions.isEmpty {
                        Section("AirPlay") {
                            ForEach(engine.airplayOptions) { Text($0.name).tag($0.id) }
                        }
                    }
                    if !engine.pairLeft.isEmpty && !engine.pairRight.isEmpty {
                        Section(L("Stereo pair")) {
                            Text(L("L %@ + R %@", Engine.displayName(engine.pairLeft), Engine.displayName(engine.pairRight)))
                                .tag(Engine.pairID)
                        }
                    }
                    // Keep a remembered speaker selectable while it is offline.
                    if let cur = engine.assignments[app.id], !allIDs.contains(cur), cur != Engine.pairID {
                        Text(L("%@ (offline)", cur)).tag(cur)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
            }
            if isRouted && !isPair {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.fill").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: gain, in: 0 ... 1).controlSize(.mini)
                    Image(systemName: "speaker.wave.3.fill").font(.caption2).foregroundStyle(.secondary)
                    Text("\(Int((gain.wrappedValue * 100).rounded())) %")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                .help(engine.isNetworkRoute(app.id) ? L("The speaker’s own volume") : L("Volume of this app"))
                .padding(.leading, 30)
            }
            if let s = engine.status[app.id] {
                Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .padding(.leading, 30)
            }
        }
    }

    private var allIDs: Set<String> {
        Set((engine.localOptions + engine.castOptions + engine.airplayOptions).map(\.id))
    }
}

/// Settings for the cross-protocol stereo pair: which speaker plays which channel,
/// per-speaker volume, the alignment delay and the calibration clicks.
struct StereoPairPanel: View {
    @ObservedObject var engine: Engine

    private var networkOptions: [DestinationOption] { engine.castOptions + engine.airplayOptions }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            speakerRow(L("Left"), selection: $engine.pairLeft, key: Engine.pairLeftKey, status: engine.pairStatusL)
            speakerRow(L("Right"), selection: $engine.pairRight, key: Engine.pairRightKey, status: engine.pairStatusR)
            if !engine.pairLeft.isEmpty && engine.pairLeft == engine.pairRight {
                Text(L("Pick two different speakers.")).font(.caption).foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(L("Offset")).font(.caption)
                    Spacer()
                    Text(delayLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    nudge(-100, "«"); nudge(-10, "‹")
                    Slider(value: $engine.pairDelayMs, in: -20000 ... 20000, step: 10).controlSize(.mini)
                    nudge(10, "›"); nudge(100, "»")
                }
            }

            Toggle(L("Calibration clicks"), isOn: $engine.pairClicks).font(.caption)
            Text(hint).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }

    private var delayLabel: String {
        let ms = Int(engine.pairDelayMs)
        if ms == 0 { return L("0 ms") }
        return ms > 0 ? L("right is %ld ms later", ms) : L("left is %ld ms later", -ms)
    }

    private var hint: String {
        if !engine.pairIsActive {
            return L("Pick the speakers, then choose “Stereo pair” for an app. Sound arrives ≈2–5 s late.")
        }
        return engine.pairClicks
            ? L("Every 10 s there is a long beep: first line up the beeps (« »), then the clicks (‹ ›). The slider holds back whichever speaker sounds first.")
            : L("Turn on the clicks to line the speakers up. After a pause or rebuffering on Chromecast the offset may drift.")
    }

    private func nudge(_ ms: Double, _ label: String) -> some View {
        Button(label) { engine.pairDelayMs = max(-20000, min(20000, engine.pairDelayMs + ms)) }
            .buttonStyle(.borderless)
            .help(L("%@ ms", "\(ms > 0 ? "+" : "")\(Int(ms))"))
    }

    private func speakerRow(_ title: String, selection: Binding<String>, key: String, status: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption).frame(width: 50, alignment: .leading)
                Picker("", selection: selection) {
                    Text("—").tag("")
                    ForEach(networkOptions) { o in
                        Text("\(o.name) (\(o.id.hasPrefix("cast:") ? "Chromecast" : "AirPlay"))").tag(o.id)
                    }
                    if !selection.wrappedValue.isEmpty && !networkOptions.contains(where: { $0.id == selection.wrappedValue }) {
                        Text(L("%@ (offline)", Engine.displayName(selection.wrappedValue))).tag(selection.wrappedValue)
                    }
                }
                .labelsHidden()
            }
            if engine.pairIsActive {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.fill").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(engine.gains[key] ?? 0.6) },
                                          set: { engine.setPairVolume(Float($0), side: key) }), in: 0 ... 1)
                        .controlSize(.mini)
                    Text("\(Int(((engine.gains[key] ?? 0.6) * 100).rounded())) %")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                }
                .padding(.leading, 56)
            }
            if let status {
                Text(status).font(.caption2).foregroundStyle(.secondary).padding(.leading, 56)
            }
        }
    }
}

/// One slider for everything AudioHub plays, plus mute.
struct MasterVolumeRow: View {
    @ObservedObject var engine: Engine

    var body: some View {
        HStack(spacing: 8) {
            Button { engine.toggleMute() } label: {
                Image(systemName: icon).frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(engine.muted ? L("Unmute") : L("Mute all speakers"))
            Slider(value: Binding(get: { Double(engine.master) }, set: { engine.setMaster(Float($0)) }), in: 0 ... 1)
                .controlSize(.small)
                .opacity(engine.muted ? 0.5 : 1)
            Text(engine.muted ? L("off") : "\(Int((engine.master * 100).rounded())) %")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .help(L("Overall volume of everything AudioHub plays"))
    }

    private var icon: String {
        if engine.muted || engine.master == 0 { return "speaker.slash.fill" }
        return engine.master < 0.34 ? "speaker.wave.1.fill" : engine.master < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}

/// Globe button with the UI language choices.
struct LanguageMenu: View {
    @ObservedObject var engine: Engine

    var body: some View {
        Menu {
            Picker(L("Language"), selection: $engine.language) {
                Text(L("System language")).tag("")
                Divider()
                ForEach(Language.supported, id: \.code) { Text($0.name).tag($0.code) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "globe")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("Language"))
    }
}

/// Shown at the top of the menu when there is something to say about updates.
struct UpdateBanner: View {
    @ObservedObject var updates: UpdateManager
    let language: String   // re-render when the UI language changes

    var body: some View {
        switch updates.state {
        case .idle:
            EmptyView()
        case .checking:
            row(icon: nil) { Text(L("Checking for updates…")) }
        case .upToDate:
            row(icon: "checkmark.circle.fill", tint: .green) { Text(L("AudioHub is up to date.")) }
        case .available(let release):
            row(icon: "arrow.down.circle.fill", tint: .accentColor) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Version %@ is available", release.version)).fontWeight(.semibold)
                    Button(L("What’s new")) { updates.openReleasePage(release) }
                        .buttonStyle(.link).font(.caption)
                }
                Spacer()
                if updates.canInstallInApp && release.isInstallable {
                    Button(L("Install")) { Task { await updates.install(release) } }
                        .controlSize(.small)
                        .help(L("Download, verify and install, then restart AudioHub"))
                } else {
                    Button(L("Download")) { updates.openReleasePage(release) }
                        .controlSize(.small)
                        .help(L("This copy was built from source: download the release or rebuild"))
                }
            }
        case .working(let step):
            row(icon: nil) { Text(step) }
        case .failed(let message):
            row(icon: "exclamationmark.triangle.fill", tint: .orange) {
                Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(L("OK")) { updates.dismiss() }.controlSize(.small)
            }
        }
    }

    private func row<Content: View>(icon: String?, tint: Color = .secondary,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if let icon {
                Image(systemName: icon).foregroundStyle(tint)
            } else {
                ProgressView().controlSize(.small)
            }
            content()
        }
        .font(.callout)
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Gear button: check now, automatic checks, version.
struct UpdateMenu: View {
    @ObservedObject var updates: UpdateManager
    let language: String

    var body: some View {
        Menu {
            Button(L("Check for Updates")) { Task { await updates.check(userInitiated: true) } }
            Toggle(L("Check Automatically"), isOn: $updates.autoCheck)
            Divider()
            Text(L("Version %@", AppVersion.current))
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("Updates"))
    }
}

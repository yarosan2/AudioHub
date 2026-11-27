import AppKit
import CryptoKit
import Foundation
import Security

// Self-update from GitHub Releases.
//
// Trust chain for an installed update:
//  1. the zip is signed with the project's Ed25519 key (public half in Info.plist,
//     private half only in the maintainer's keychain) — a compromised GitHub account
//     alone cannot ship an update;
//  2. the app inside must carry a valid code signature that satisfies the *running* app's
//     designated requirement (same identifier, same certificate) — so macOS privacy
//     permissions carry over and a differently signed app is never swapped in;
//  3. it must be the same bundle identifier and a strictly newer version.

// MARK: - Versions

enum AppVersion {
    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// "v0.10.2" → [0, 10, 2]. Non-numeric parts end the version ("1.2.0-beta" → [1, 2, 0]).
    static func components(_ s: String) -> [Int] {
        let trimmed = s.hasPrefix("v") || s.hasPrefix("V") ? String(s.dropFirst()) : s
        var out: [Int] = []
        for part in trimmed.split(separator: ".") {
            let digits = part.prefix { $0.isNumber }
            guard let n = Int(digits) else { break }
            out.append(n)
            if digits.count != part.count { break }
        }
        return out
    }

    /// Numeric comparison, missing parts count as 0 (1.2 == 1.2.0).
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = components(a), y = components(b)
        for i in 0 ..< max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }
}

// MARK: - Release info from the GitHub API

struct ReleaseInfo: Equatable {
    let version: String     // without the leading "v"
    let pageURL: URL
    let notes: String
    let zipURL: URL?
    let zipSize: Int?
    let signatureURL: URL?

    /// Both the archive and its signature are attached: the release can be installed in-app.
    var isInstallable: Bool { zipURL != nil && signatureURL != nil }

    /// Parses GET /repos/{owner}/{repo}/releases/latest.
    static func parse(_ data: Data) throws -> ReleaseInfo {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let page = (obj["html_url"] as? String).flatMap(URL.init(string:))
        else { throw UserError(L("Unexpected answer from GitHub.")) }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = obj["assets"] as? [[String: Any]] ?? []
        func asset(_ name: String) -> [String: Any]? { assets.first { $0["name"] as? String == name } }
        // Prefer the conventional name; otherwise the only .zip attached.
        let zip = asset("AudioHub-\(version).zip")
            ?? { let zips = assets.filter { ($0["name"] as? String)?.hasSuffix(".zip") == true }
                 return zips.count == 1 ? zips[0] : nil }()
        let zipName = zip?["name"] as? String
        let sig = zipName.flatMap { asset($0 + ".sig") }
        return ReleaseInfo(
            version: version,
            pageURL: page,
            notes: obj["body"] as? String ?? "",
            zipURL: (zip?["browser_download_url"] as? String).flatMap(URL.init(string:)),
            zipSize: zip?["size"] as? Int,
            signatureURL: (sig?["browser_download_url"] as? String).flatMap(URL.init(string:)))
    }
}

// MARK: - Ed25519 update signatures

enum UpdateSignature {
    /// Signature file format: base64 of the 64-byte Ed25519 signature over the whole zip.
    static func sign(_ data: Data, with key: Curve25519.Signing.PrivateKey) throws -> String {
        try key.signature(for: data).base64EncodedString()
    }

    static func verify(_ data: Data, signature: String, publicKey: String) -> Bool {
        guard let sig = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              let raw = Data(base64Encoded: publicKey.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        else { return false }
        return key.isValidSignature(sig, for: data)
    }
}

/// The maintainer's private signing key, kept in the login keychain (never in the repository).
///
/// Key rotation keeps installed copies updatable: `active` is the key installed apps trust;
/// `next` is its successor. A *transition release* ships the next public key in Info.plist but
/// is signed with the active key, so current installs accept it. After it is out,
/// `update-keygen --finish-rotation` makes the next key active and deletes the old one.
enum SigningKeyStore {
    static let service = "AudioHub update signing key"
    static let active = "ed25519"
    static let next = "ed25519-next"

    static func load(_ account: String = active) -> Curve25519.Signing.PrivateKey? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    static func save(_ key: Curve25519.Signing.PrivateKey, as account: String = active) throws {
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account,
                                   kSecAttrLabel as String: account == active ? service : service + " (next)",
                                   kSecValueData as String: key.rawRepresentation]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw UserError("Keychain error \(status)") }
    }

    static func delete(_ account: String) throws {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(q as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw UserError("Keychain error \(status)") }
    }

    static func publicKey(of key: Curve25519.Signing.PrivateKey) -> String {
        key.publicKey.rawRepresentation.base64EncodedString()
    }

    enum SigningPlan: Equatable { case normal, transition, mismatch }

    /// Which kind of release a build is, given the public key embedded in it.
    /// Signing always uses the active key; the embedded key may be the active one (normal)
    /// or its successor (transition release). Anything else would brick updates.
    static func plan(embedded: String, activeKey: String, nextKey: String?) -> SigningPlan {
        if embedded == activeKey { return .normal }
        if let nextKey, embedded == nextKey { return .transition }
        return .mismatch
    }
}

// MARK: - Code signature identity

enum CodeIdentity {
    /// The running app's designated requirement ("identifier X and certificate leaf = H").
    static func runningAppRequirement() -> SecRequirement? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var req: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &req) == errSecSuccess else { return nil }
        return req
    }

    static func describe(_ req: SecRequirement) -> String {
        var text: CFString?
        SecRequirementCopyString(req, [], &text)
        return (text as String?) ?? "?"
    }

    /// Checks that the bundle at `url` is intact (all files sealed by its signature) and signed
    /// by the same identity as `requirement` describes.
    static func validate(_ url: URL, against requirement: SecRequirement) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess
    }

    /// Ad-hoc signatures have no certificate; their requirement is the exact code hash.
    static var runningAppIsAdHoc: Bool {
        guard let req = runningAppRequirement() else { return true }
        return !describe(req).contains("certificate")
    }
}

// MARK: - Configuration

enum UpdateConfig {
    /// "owner/repo" whose GitHub releases are checked.
    static var repository: String? { Bundle.main.infoDictionary?["AHUpdateRepository"] as? String }
    /// Base64 Ed25519 public key that release archives must be signed with.
    static var publicKey: String? {
        (Bundle.main.infoDictionary?["AHUpdatePublicKey"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    /// Set only by scripts/release.sh. Builds from source get notifications, not installs.
    static var isReleaseBuild: Bool { Bundle.main.infoDictionary?["AHReleaseBuild"] as? Bool ?? false }

    /// API origin; tests point it at a local server (selftest sets `apiBaseOverride`).
    static var apiBaseOverride: URL?
    static var apiBase: URL {
        apiBaseOverride
            ?? ProcessInfo.processInfo.environment["AUDIOHUB_UPDATE_API"].flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com")!
    }

    /// Downloads are only accepted from GitHub (or loopback when the API is overridden for tests).
    static func isAllowedDownload(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if apiBase.host == "127.0.0.1" { return url.scheme == "http" && host == "127.0.0.1" }
        guard url.scheme == "https" else { return false }
        return host == "github.com" || host == "api.github.com" || host.hasSuffix(".githubusercontent.com")
    }
}

// MARK: - Installer

/// Downloads, verifies and swaps in a release. Throws before touching `target` if any check fails.
struct UpdateInstaller {
    let release: ReleaseInfo
    let publicKey: String
    /// The installed .app to replace.
    let target: URL
    /// Identity the new app must be signed with (normally the running app's).
    let requirement: SecRequirement
    var progress: (String) -> Void = { _ in }

    static let maxArchiveBytes = 100 * 1024 * 1024

    func run() async throws {
        guard let zipURL = release.zipURL, let sigURL = release.signatureURL else {
            throw UserError(L("This release has no installable archive."))
        }
        guard UpdateConfig.isAllowedDownload(zipURL), UpdateConfig.isAllowedDownload(sigURL) else {
            throw UserError(L("Refusing to download the update from an unexpected address."))
        }

        progress(L("Downloading…"))
        let signature = String(decoding: try await Self.fetch(sigURL, limit: 4_096), as: UTF8.self)
        let archive = try await Self.fetch(zipURL, limit: Self.maxArchiveBytes)
        if let size = release.zipSize, size != archive.count {
            throw UserError(L("The download is incomplete. Nothing was installed."))
        }

        progress(L("Verifying…"))
        guard UpdateSignature.verify(archive, signature: signature, publicKey: publicKey) else {
            throw UserError(L("The update’s signature is invalid. Nothing was installed."))
        }

        // Work next to the target so the final swap is a same-volume rename.
        let fm = FileManager.default
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? fm.removeItem(at: work) }
        let zipFile = work.appendingPathComponent("update.zip")
        try archive.write(to: zipFile)
        let unpacked = work.appendingPathComponent("unpacked")
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try Self.run("/usr/bin/ditto", ["-x", "-k", zipFile.path, unpacked.path])

        let newApp = unpacked.appendingPathComponent(target.lastPathComponent)
        guard let newInfo = Self.info(of: newApp), let oldInfo = Self.info(of: target) else {
            throw UserError(L("The update archive does not contain AudioHub."))
        }
        let newID = newInfo["CFBundleIdentifier"] as? String, oldID = oldInfo["CFBundleIdentifier"] as? String
        let newVersion = newInfo["CFBundleShortVersionString"] as? String ?? ""
        let oldVersion = oldInfo["CFBundleShortVersionString"] as? String ?? ""
        guard newID != nil, newID == oldID else {
            throw UserError(L("The update archive does not contain AudioHub."))
        }
        guard AppVersion.compare(newVersion, release.version) == .orderedSame,
              AppVersion.isNewer(newVersion, than: oldVersion) else {
            throw UserError(L("The update is not newer than the installed version."))
        }
        guard CodeIdentity.validate(newApp, against: requirement) else {
            throw UserError(L("The update is signed by a different developer. Nothing was installed."))
        }

        progress(L("Installing…"))
        _ = try fm.replaceItemAt(target, withItemAt: newApp)
    }

    private static func info(of app: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpAdditionalHeaders = ["User-Agent": "AudioHub-Updater"]
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    static func fetch(_ url: URL, limit: Int, headers: [String: String] = [:]) async throws -> Data {
        var req = URLRequest(url: url)
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UserError(L("Download failed (HTTP %ld).", (response as? HTTPURLResponse)?.statusCode ?? 0))
        }
        // Redirects (GitHub → its CDN) must also stay on allowed hosts.
        if let final = http.url, !UpdateConfig.isAllowedDownload(final) {
            throw UserError(L("Refusing to download the update from an unexpected address."))
        }
        guard data.count <= limit else { throw UserError(L("The download is too large.")) }
        return data
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UserError(L("Could not unpack the update.")) }
    }
}

// MARK: - Update manager (UI state)

@MainActor
final class UpdateManager: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case working(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published var autoCheck: Bool {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "updateAutoCheck") }
    }
    private var timer: Timer?

    static let checkInterval: TimeInterval = 24 * 60 * 60

    /// In-app install is offered only for signed release builds in a writable location;
    /// builds from source just link to the release page.
    var canInstallInApp: Bool {
        UpdateConfig.isReleaseBuild && UpdateConfig.publicKey != nil && !CodeIdentity.runningAppIsAdHoc
            && FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path)
    }

    init() {
        autoCheck = UserDefaults.standard.object(forKey: "updateAutoCheck") as? Bool ?? true
        guard UpdateConfig.repository != nil else { return }
        // First check shortly after launch, then hourly ticks that check once a day.
        timer = Timer.scheduledTimer(withTimeInterval: 3_600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            self.checkIfDue()
        }
    }

    private func checkIfDue() {
        guard autoCheck else { return }
        let last = UserDefaults.standard.object(forKey: "updateLastCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.checkInterval else { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        guard let repo = UpdateConfig.repository else { return }
        if case .working = state { return }
        if userInitiated { state = .checking }   // background checks stay invisible
        do {
            let url = UpdateConfig.apiBase.appendingPathComponent("repos/\(repo)/releases/latest")
            let data = try await UpdateInstaller.fetch(url, limit: 1_000_000,
                                                       headers: ["Accept": "application/vnd.github+json"])
            let release = try ReleaseInfo.parse(data)
            UserDefaults.standard.set(Date(), forKey: "updateLastCheck")
            if AppVersion.isNewer(release.version, than: AppVersion.current) {
                state = .available(release)
            } else if userInitiated {
                state = .upToDate
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if state == .upToDate { state = .idle }
            } else {
                state = .idle
            }
        } catch {
            // Background checks fail quietly (offline, rate limit); manual ones explain.
            state = userInitiated ? .failed(L("Could not check for updates: %@", "\(error)")) : .idle
        }
    }

    func install(_ release: ReleaseInfo) async {
        guard let key = UpdateConfig.publicKey, let requirement = CodeIdentity.runningAppRequirement() else {
            state = .failed(L("In-app updates are not available for this build."))
            return
        }
        var installer = UpdateInstaller(release: release, publicKey: key, target: Bundle.main.bundleURL,
                                        requirement: requirement)
        installer.progress = { [weak self] s in Task { @MainActor in self?.state = .working(s) } }
        state = .working(L("Downloading…"))
        do {
            try await installer.run()
            relaunch()
        } catch {
            state = .failed("\(error)")
        }
    }

    func dismiss() { state = .idle }

    func openReleasePage(_ release: ReleaseInfo) {
        NSWorkspace.shared.open(release.pageURL)
    }

    /// Starts the new copy once this process has exited, then quits (routes are torn down on quit).
    private func relaunch() {
        let path = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}

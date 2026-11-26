import Foundation

/// Localized string. Keys are the English text; translations live in
/// Resources/<lang>.lproj/Localizable.strings. Arguments use printf-style placeholders.
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = Language.bundle.localizedString(forKey: key, value: key, table: nil)
    return args.isEmpty ? format : String(format: format, locale: Language.locale, arguments: args)
}

/// The app's UI language. Stored as the app's own `AppleLanguages` preference — the same
/// setting macOS writes from System Settings → Language & Region → Applications — so the
/// in-app menu and System Settings stay in agreement. Switching takes effect immediately.
enum Language {
    static let supported: [(code: String, name: String)] = [
        ("en", "English"), ("ru", "Русский"), ("uk", "Українська"),
    ]

    /// "" = follow the system; otherwise one of `supported`.
    static var selected: String {
        get {
            let app = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
            let first = (app?["AppleLanguages"] as? [String])?.first ?? ""
            return match(first) ?? ""
        }
        set {
            if newValue.isEmpty {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
            }
            cachedBundle = nil
        }
    }

    /// Language actually shown: the selection, or the best match for the system languages.
    static var effective: String {
        if !selected.isEmpty { return selected }
        let global = UserDefaults(suiteName: UserDefaults.globalDomain)?.stringArray(forKey: "AppleLanguages") ?? []
        return global.lazy.compactMap(match).first ?? "en"
    }

    static var locale: Locale { Locale(identifier: effective) }

    static var bundle: Bundle {
        if let b = cachedBundle { return b }
        let b = Bundle.main.path(forResource: effective, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        cachedBundle = b
        return b
    }
    private static var cachedBundle: Bundle?

    /// "uk-EE" → "uk", "en-US" → "en"; nil if unsupported.
    private static func match(_ tag: String) -> String? {
        let base = String(tag.prefix { $0 != "-" && $0 != "_" })
        return supported.contains { $0.code == base } ? base : nil
    }
}

/// An error meant to be shown to the user as-is.
struct UserError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

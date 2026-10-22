import Foundation
import os

/// Resolves resources both from SwiftPM development builds and from the
/// code-sign-safe nested bundle installed in `Contents/Resources`.
enum AppResources {
    static let bundle: Bundle = {
        if let url = Bundle.main.url(
            forResource: "SysBar_SysBar",
            withExtension: "bundle"
        ), let installedBundle = Bundle(url: url) {
            return installedBundle
        }
        return .module
    }()

    /// Every visible row asks for the same few strings on every render. The
    /// bundle's answer for a key never changes while the app runs, so each
    /// lookup (and each plural phrase) is resolved once and then reused.
    private struct LookupKey: Hashable {
        let key: String
        let fallback: String?
        let count: Int?
    }

    private static let lookupCapacity = 1_024
    private static let lookups = OSAllocatedUnfairLock(initialState: [LookupKey: String]())

    // Out of line: every user-facing string calls these, and inlining the
    // cached lookup at each call site grew the binary by about 100 KB.
    @inline(never)
    private static func cached(_ lookupKey: LookupKey, resolve: () -> String) -> String {
        if let value = lookups.withLock({ $0[lookupKey] }) { return value }
        let value = resolve()
        lookups.withLock { cache in
            if cache.count >= lookupCapacity { cache.removeAll(keepingCapacity: true) }
            cache[lookupKey] = value
        }
        return value
    }

    @inline(never)
    static func localized(_ key: String, fallback: String? = nil) -> String {
        cached(LookupKey(key: key, fallback: fallback, count: nil)) {
            bundle.localizedString(
                forKey: key,
                value: fallback ?? key,
                table: "Localizable"
            )
        }
    }

    static func formatted(
        _ key: String,
        fallback: String,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: localized(key, fallback: fallback),
            locale: Locale.current,
            arguments: arguments
        )
    }

    @inline(never)
    static func plural(_ key: String, count: Int) -> String {
        cached(LookupKey(key: key, fallback: nil, count: count)) {
            let format = bundle.localizedString(
                forKey: key,
                value: nil,
                table: "Localizable"
            )
            guard format != key else { return String(count) }
            return String.localizedStringWithFormat(format, count)
        }
    }
}

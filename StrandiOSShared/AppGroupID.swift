import Foundation

/// Resolves the App Group identifiers at runtime from the target's Info.plist.
///
/// The group ids are derived from `BUNDLE_ID_PREFIX` in `Config/Signing.xcconfig`, so a personal
/// build signed with its own team uses its own groups (`group.com.yourname.noop`). Each target
/// writes the expanded id into its Info.plist (`NOOPAppGroupID` / `NOOPWatchAppGroupID`). Targets
/// without the key, such as the unit-test bundle, fall back to the upstream ids.
public enum AppGroupID {
    public static let phoneInfoKey = "NOOPAppGroupID"
    public static let watchInfoKey = "NOOPWatchAppGroupID"
    public static let phoneFallback = "group.com.noopapp.noop"
    public static let watchFallback = "group.com.noopapp.noop.watch"

    /// App Group shared by the iPhone app and its widget extension.
    public static let phone = resolve(infoKey: phoneInfoKey, fallback: phoneFallback)
    /// App Group shared by the watch app and its complication extension.
    public static let watch = resolve(infoKey: watchInfoKey, fallback: watchFallback)

    /// Pure lookup, separated from `Bundle` so it can be unit-tested.
    public static func resolve(infoValue: Any?, fallback: String) -> String {
        guard let value = (infoValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.hasPrefix("group."),
              !value.contains("$(") else { return fallback }
        return value
    }

    public static func resolve(infoKey: String, fallback: String, bundle: Bundle = .main) -> String {
        resolve(infoValue: bundle.object(forInfoDictionaryKey: infoKey), fallback: fallback)
    }
}

import Foundation

/// Persists `SyncSettings` in UserDefaults — device-local configuration, not
/// athlete training data, so it deliberately stays out of PersistenceKit's
/// SwiftData schema.
public final class SyncSettingsStore: Sendable {
    private let defaultsKey = "com.accel.MoveLoad.syncSettings"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> SyncSettings? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(SyncSettings.self, from: data)
    }

    public func save(_ settings: SyncSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

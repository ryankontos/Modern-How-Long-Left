import Foundation

/// A short-lived local cache for the direct CloudKit settings projection.
///
/// Extensions are frequently asked for several configurations together. This
/// cache prevents each provider invocation from repeating the same network
/// request while keeping the durable source in private CloudKit.
public struct HLLSharedSettingsCacheEntry: Codable, Sendable {
    public let checkedAt: Date
    public let projection: HLLSharedSettingsProjection?
}

public struct HLLSharedSettingsCacheStore: Sendable {
    private let groupIdentifier: String

    public init(groupIdentifier: String) {
        self.groupIdentifier = groupIdentifier
    }

    public func read() -> HLLSharedSettingsCacheEntry? {
        guard let url = fileURL(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HLLSharedSettingsCacheEntry.self, from: data)
    }

    public func write(_ projection: HLLSharedSettingsProjection?, checkedAt: Date = .now) {
        guard let url = fileURL(),
              let data = try? JSONEncoder().encode(
                HLLSharedSettingsCacheEntry(checkedAt: checkedAt, projection: projection)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func fileURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier)?
            .appending(path: "HLLSharedSettingsCache.json")
    }
}

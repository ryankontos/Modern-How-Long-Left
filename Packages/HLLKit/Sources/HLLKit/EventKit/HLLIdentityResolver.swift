import Foundation

/// Local aliases preserve animation identity when EventKit changes its identifiers.
public struct HLLIdentityRecord: Codable, Sendable {
    public let alias: String
    public let eventID: UUID
    public let fingerprint: String
    public let updatedAt: Date
}

public actor HLLIdentityResolver {
    private let database: HLLDatabase
    private var records: [String: HLLIdentityRecord] = [:]
    private var byFingerprint: [String: Set<UUID>] = [:]
    private var loaded = false

    public init(database: HLLDatabase) { self.database = database }

    public func resolve(_ event: HLLEventKitSource.RawEvent,
                        calendarProfileID: UUID?) async throws -> (id: UUID, portableKey: String?) {
        if !loaded { try await load() }
        let occurrence = String(event.occurrenceStart.timeIntervalSince1970)
        let scopedCalendar = event.calendarLocalID
        var aliases: [String] = []
        if let external = event.externalID, !external.isEmpty {
            aliases.append("external|\(scopedCalendar)|\(external)|\(occurrence)")
        }
        if let local = event.localID, !local.isEmpty {
            aliases.append("local|\(scopedCalendar)|\(local)|\(occurrence)")
        }
        // A fingerprint is used only when it identifies a single previously seen event.
        let fingerprint = [scopedCalendar, occurrence, event.title.folding(options: [.caseInsensitive], locale: nil),
                           String(event.end.timeIntervalSince1970 - event.start.timeIntervalSince1970)]
            .joined(separator: "|")
        let exact = aliases.compactMap { records[$0]?.eventID }.first
        let uniqueFingerprint = byFingerprint[fingerprint].flatMap { $0.count == 1 ? $0.first : nil }
        let id = exact ?? uniqueFingerprint ?? UUID()
        // Touch active aliases weekly, avoiding a write on every widget or app refresh.
        for alias in aliases {
            if let old = records[alias], Date().timeIntervalSince(old.updatedAt) > 7 * 86_400 {
                let touched = HLLIdentityRecord(alias: alias, eventID: old.eventID,
                                                fingerprint: fingerprint, updatedAt: .now)
                try await database.put(touched, kind: .eventIdentity, key: alias, location: .local)
                records[alias] = touched
            }
        }
        for alias in aliases where records[alias]?.eventID != id {
            let record = HLLIdentityRecord(alias: alias, eventID: id,
                                           fingerprint: fingerprint, updatedAt: .now)
            try await database.put(record, kind: .eventIdentity, key: alias, location: .local)
            records[alias] = record
        }
        byFingerprint[fingerprint, default: []].insert(id)
        let portableKey: String?
        if let external = event.externalID, let profile = calendarProfileID {
            portableKey = "\(profile.uuidString)|\(external)|\(occurrence)"
        } else { portableKey = nil }
        return (id, portableKey)
    }

    private func load() async throws {
        let saved: [HLLIdentityRecord] = try await database.all(
            HLLIdentityRecord.self, kind: .eventIdentity, location: .local)
        records = Dictionary(saved.map { ($0.alias, $0) }, uniquingKeysWith: { lhs, rhs in
            lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
        })
        for record in records.values { byFingerprint[record.fingerprint, default: []].insert(record.eventID) }
        loaded = true
    }
}

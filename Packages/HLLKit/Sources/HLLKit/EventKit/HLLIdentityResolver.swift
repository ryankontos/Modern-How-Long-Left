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
    private var pendingRecords: [String: HLLIdentityRecord] = [:]
    private var flushTask: Task<Void, Never>?
    private var loaded = false

    public init(database: HLLDatabase) { self.database = database }

    public func resolve(_ event: HLLEventKitSource.RawEvent,
                        calendarProfileID: UUID?) async throws -> (id: UUID, portableKey: String?) {
        if !loaded { try await load() }
        let occurrence = String(event.occurrenceStart.timeIntervalSince1970)
        let scopedCalendar = event.calendarLocalID
        // One-off events should keep their identity when a user edits the
        // date. Repeating occurrences still need the occurrence component so
        // each occurrence remains independently addressable.
        let occurrenceComponent = event.hasRecurrence ? "|\(occurrence)" : ""
        var aliases: [String] = []
        if let external = event.externalID, !external.isEmpty {
            // Prefer the durable calendar profile when available. EventKit can
            // replace a local calendar identifier after an account refresh,
            // while the profile and external item identifier remain stable.
            if let calendarProfileID {
                aliases.append("external|profile|\(calendarProfileID.uuidString)|\(external)\(occurrenceComponent)")
            }
            aliases.append("external|calendar|\(scopedCalendar)|\(external)\(occurrenceComponent)")
        }
        if let local = event.localID, !local.isEmpty {
            aliases.append("local|\(scopedCalendar)|\(local)\(occurrenceComponent)")
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
                records[alias] = touched
                enqueue(touched)
            }
        }
        for alias in aliases where records[alias]?.eventID != id {
            let record = HLLIdentityRecord(alias: alias, eventID: id,
                                           fingerprint: fingerprint, updatedAt: .now)
            records[alias] = record
            enqueue(record)
        }
        byFingerprint[fingerprint, default: []].insert(id)
        let portableKey: String?
        if let external = event.externalID, let profile = calendarProfileID {
            portableKey = "\(profile.uuidString)|\(external)\(occurrenceComponent)"
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

    /// Identity writes are not on the launch-critical query path. A small
    /// coalescing queue keeps the resolver fast when a calendar has many
    /// occurrences while still persisting aliases shortly after the snapshot.
    private func enqueue(_ record: HLLIdentityRecord) {
        pendingRecords[record.alias] = record
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            await self?.flushPending()
        }
    }

    private func flushPending() async {
        let records = pendingRecords.values
        pendingRecords.removeAll(keepingCapacity: true)
        flushTask = nil
        for record in records {
            try? await database.put(record, kind: .eventIdentity,
                                    key: record.alias, location: .local)
        }
        if !pendingRecords.isEmpty { enqueueNextFlush() }
    }

    private func enqueueNextFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            await self?.flushPending()
        }
    }
}

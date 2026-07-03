import BackgroundTasks
import Foundation
import HealthKit
import OSLog

private let log = Logger(subsystem: "io.sazanka.vitalsync", category: "SyncEngine")

// MARK: - Sync state

enum SyncError: LocalizedError {
    case deviceNotRegistered
    case batchTooLarge
    case healthDataUnavailable
    case healthAuthorizationNotDetermined
    case unmappedHealthSamples(VitalsyncSampleType, Int, Int)
    case serverRejected(ServerError)
    case transportUnavailable

    var errorDescription: String? {
        switch self {
        case .deviceNotRegistered:   return "Device not registered with receiver."
        case .batchTooLarge:         return "Batch too large even after split."
        case .healthDataUnavailable: return "Health data is not available on this device."
        case .healthAuthorizationNotDetermined: return "Health access is not authorized. Open Data types and grant Health access."
        case .unmappedHealthSamples(let sampleType, let raw, let mapped):
            return "Could not map all \(sampleType.rawValue) samples (\(mapped) of \(raw) mapped)."
        case .serverRejected(let e): return "Receiver error: \(e.message)"
        case .transportUnavailable:  return "Transport unavailable."
        }
    }
}

struct SyncResult {
    var totalRecords: Int = 0
    var totalDeleted: Int = 0
    var batchesSent: Int = 0
    var errors: [Error] = []
    var completedAt: Date = .now
}

enum SyncTrigger: String, Codable {
    case manual
    case shortcut
    case backgroundHealthKit
    case backgroundRefresh
    case retryPending

    var displayName: String {
        switch self {
        case .manual: return "Manual"
        case .shortcut: return "Shortcut"
        case .backgroundHealthKit: return "Background HealthKit"
        case .backgroundRefresh: return "Background refresh"
        case .retryPending: return "Retry pending"
        }
    }
}

enum SyncOutcome: String, Codable {
    case running
    case succeeded
    case deferred
    case failed

    var displayName: String {
        switch self {
        case .running: return "Running"
        case .succeeded: return "Succeeded"
        case .deferred: return "Deferred"
        case .failed: return "Failed"
        }
    }
}

struct SyncHistoryEntry: Identifiable, Codable {
    let id: UUID
    let trigger: SyncTrigger
    let startedAt: Date
    var completedAt: Date?
    var outcome: SyncOutcome
    var records: Int
    var deleted: Int
    var batches: Int
    var error: String?
}

struct SyncDiagnosticEvent: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let message: String
}

// MARK: - Pending queue (local encrypted retry queue)

struct PendingBatchLoad {
    let batches: [VitalsyncBatch]
    let quarantinedFiles: [String]
}

actor PendingQueue {
    private let dir: URL

    init() {
        let app = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        dir = app.appendingPathComponent("queue", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func enqueue(_ batch: VitalsyncBatch) throws {
        let url = dir.appendingPathComponent("pending-\(batch.batchId).json")
        let data = try JSONEncoder.vitalsync.encode(batch)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        log.info("Queued batch \(batch.batchId) (\(data.count) bytes)")
    }

    func pendingBatches() throws -> PendingBatchLoad {
        let files = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("pending-") }
        var batches: [VitalsyncBatch] = []
        var quarantinedFiles: [String] = []

        for url in files {
            do {
                let data = try Data(contentsOf: url)
                batches.append(try JSONDecoder.vitalsync.decode(VitalsyncBatch.self, from: data))
            } catch {
                let loadError = error
                let filename = url.lastPathComponent
                do {
                    try quarantineUnreadableBatch(at: url)
                    quarantinedFiles.append(filename)
                    log.error("Quarantined unreadable pending batch \(filename): \(loadError.localizedDescription)")
                } catch {
                    log.error("Failed to quarantine unreadable pending batch \(filename): \(error.localizedDescription); load error: \(loadError.localizedDescription)")
                    throw loadError
                }
            }
        }

        return PendingBatchLoad(
            batches: batches.sorted { $0.sequence < $1.sequence },
            quarantinedFiles: quarantinedFiles
        )
    }

    func dequeue(batchId: String) {
        let url = dir.appendingPathComponent("pending-\(batchId).json")
        try? FileManager.default.removeItem(at: url)
    }

    func count() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("pending-") }.count) ?? 0
    }

    private func quarantineUnreadableBatch(at url: URL) throws {
        let quarantinedName = "invalid-\(Int(Date().timeIntervalSince1970))-\(url.lastPathComponent)"
        let destination = dir.appendingPathComponent(quarantinedName)
        try FileManager.default.moveItem(at: url, to: destination)
    }
}

// MARK: - SyncEngine

@MainActor
final class SyncEngine: ObservableObject {
    private let hkManager: HealthKitManager
    private let transport: TransportManager
    private let credentials: CredentialStore
    private let queue = PendingQueue()

    @Published var isSyncing = false
    @Published var lastSyncDate: Date?
    @Published var lastAttemptDate: Date?
    @Published var lastError: String?
    @Published var lastBatchCount: Int = 0
    @Published var lastSuccessfulBatchCount: Int = 0
    @Published var lastRecordCount: Int = 0
    @Published var lastDeletedCount: Int = 0
    @Published var pendingCount: Int = 0
    @Published var syncStatus: String?
    @Published var syncHistory: [SyncHistoryEntry] = []
    @Published var diagnosticEvents: [SyncDiagnosticEvent] = []
    @Published var backgroundSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(backgroundSyncEnabled, forKey: Self.backgroundSyncEnabledKey)
            if backgroundSyncEnabled {
                scheduleBackgroundSync()
            } else {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundRefreshTaskIdentifier)
            }
        }
    }

    private var sequenceCounter: Int = 0

    static let backgroundRefreshTaskIdentifier = "io.sazanka.vitalsync.refresh"
    static let maxBatchBytes = 1_048_576   // 1 MiB
    private static let backgroundSyncEnabledKey = "background_sync_enabled"
    private static let lastSyncDateKey = "last_sync_date"
    private static let lastAttemptDateKey = "last_attempt_date"
    private static let lastErrorKey = "last_error"
    private static let lastBatchCountKey = "last_batch_count"
    private static let lastSuccessfulBatchCountKey = "last_successful_batch_count"
    private static let lastRecordCountKey = "last_record_count"
    private static let lastDeletedCountKey = "last_deleted_count"
    private static let syncHistoryKey = "sync_history"
    private static let diagnosticEventsKey = "sync_diagnostic_events"
    private static let minimumBackgroundSyncInterval: TimeInterval = 6 * 60 * 60
    private static let maxHistoryEntries = 50
    private static let maxDiagnosticEvents = 200

    init(hkManager: HealthKitManager, transport: TransportManager, credentials: CredentialStore) {
        self.hkManager = hkManager
        self.transport = transport
        self.credentials = credentials
        backgroundSyncEnabled = UserDefaults.standard.bool(forKey: Self.backgroundSyncEnabledKey)
        loadSyncState()
        Task { pendingCount = await queue.count() }
    }

    // MARK: Manual sync

    func syncNow(typeGroups: [VitalsyncTypeGroup], trigger: SyncTrigger = .manual) async {
        guard !isSyncing else {
            recordDiagnosticEvent("Ignored \(trigger.displayName) sync because another sync is running")
            return
        }
        isSyncing = true
        let historyId = appendHistoryEntry(trigger: trigger)
        recordDiagnosticEvent("Sync started: \(trigger.displayName)")
        lastAttemptDate = .now
        lastError = nil
        lastBatchCount = 0
        lastRecordCount = 0
        lastDeletedCount = 0
        syncStatus = "Preparing"
        var result = SyncResult()
        saveSyncState()

        do {
            let enabledGroups = typeGroups.filter(\.enabled)
            try await ensureHealthAuthorization(for: enabledGroups)

            // 1. Query all enabled type groups incrementally
            var allRecords: [VitalsyncRecord] = []
            var allDeleted: [VitalsyncTombstone] = []
            var queryResults: [VitalsyncQueryResult] = []

            for group in enabledGroups {
                for hkType in group.queryTypes {
                    guard let vitalsyncType = hkManager.vitalsyncSampleType(for: hkType) else { continue }
                    syncStatus = "Querying \(vitalsyncType.rawValue)"
                    let qr = try await hkManager.queryIncremental(sampleType: hkType, vitalsyncType: vitalsyncType)
                    guard qr.rawSampleCount == qr.mappedSampleCount else {
                        throw SyncError.unmappedHealthSamples(vitalsyncType, qr.rawSampleCount, qr.mappedSampleCount)
                    }
                    queryResults.append(qr)
                    allRecords.append(contentsOf: qr.records)
                    allDeleted.append(contentsOf: qr.tombstones)
                }
            }

            result.totalRecords = allRecords.count
            result.totalDeleted = allDeleted.count
            lastRecordCount = result.totalRecords
            lastDeletedCount = result.totalDeleted

            // 2. Split into batches ≤ 1 MiB, newest 30 days first
            syncStatus = "Building batches: 0 of \(allRecords.count) records"
            let batches = try await splitIntoBatches(records: allRecords, deleted: allDeleted)
            syncStatus = "Prepared \(batches.count) new batch(es)"

            // 3. Upload each batch (retry pending first, then new)
            let pending = try await queue.pendingBatches()
            let uploadBatches = pending.batches + batches
            for (index, batch) in uploadBatches.enumerated() {
                syncStatus = "Uploading \(index + 1) of \(uploadBatches.count): \(batch.records.count) records"
                try await uploadWithFallback(batch)
                await queue.dequeue(batchId: batch.batchId)
                result.batchesSent += 1
            }

            syncStatus = "Saving sync history"
            for queryResult in queryResults {
                await hkManager.commitAnchor(for: queryResult)
            }

            result.completedAt = .now
            lastSyncDate = result.completedAt
            lastAttemptDate = result.completedAt
            lastBatchCount = result.batchesSent
            lastSuccessfulBatchCount = result.batchesSent
            if !pending.quarantinedFiles.isEmpty {
                lastError = queueWarning(for: pending.quarantinedFiles)
            }
            log.info("Sync complete: \(result.totalRecords) records, \(result.batchesSent) batches")
            recordDiagnosticEvent("Sync succeeded: \(trigger.displayName), records=\(result.totalRecords), batches=\(result.batchesSent)")
            finishHistoryEntry(
                id: historyId,
                outcome: .succeeded,
                completedAt: result.completedAt,
                records: result.totalRecords,
                deleted: result.totalDeleted,
                batches: result.batchesSent,
                error: lastError
            )

        } catch {
            result.completedAt = .now
            lastAttemptDate = result.completedAt
            lastBatchCount = result.batchesSent
            let outcome: SyncOutcome
            if shouldDeferProtectedHealthDataError(error, trigger: trigger) {
                outcome = .deferred
                lastError = "Protected health data is inaccessible; deferred until device unlock or HealthKit wake."
                log.info("Sync deferred because protected Health data is inaccessible")
                recordDiagnosticEvent("Sync deferred: \(trigger.displayName), protected Health data inaccessible")
            } else {
                outcome = .failed
                lastError = error.localizedDescription
                log.error("Sync failed: \(error.localizedDescription)")
                recordDiagnosticEvent("Sync failed: \(trigger.displayName), error=\(error.localizedDescription)")
            }
            finishHistoryEntry(
                id: historyId,
                outcome: outcome,
                completedAt: result.completedAt,
                records: result.totalRecords,
                deleted: result.totalDeleted,
                batches: result.batchesSent,
                error: lastError
            )
        }

        pendingCount = await queue.count()
        saveSyncState()
        syncStatus = nil
        isSyncing = false
    }

    private func ensureHealthAuthorization(for groups: [VitalsyncTypeGroup]) async throws {
        guard HealthKitManager.isHealthDataAvailable else {
            throw SyncError.healthDataUnavailable
        }
        guard !groups.isEmpty else { return }

        let requestStatus = try await hkManager.authorizationRequestStatus(groups: groups)
        switch requestStatus {
        case .shouldRequest:
            await hkManager.refreshReadAuthorizationStatus(for: groups)
            throw SyncError.healthAuthorizationNotDetermined
        case .unknown:
            await hkManager.refreshReadAuthorizationStatus(for: groups)
            throw SyncError.healthAuthorizationNotDetermined
        case .unnecessary:
            await hkManager.refreshReadAuthorizationStatus(for: groups)
        @unknown default:
            await hkManager.refreshReadAuthorizationStatus(for: groups)
            throw SyncError.healthAuthorizationNotDetermined
        }
    }

    // MARK: Retry pending

    func retryPending() async {
        guard !isSyncing else {
            recordDiagnosticEvent("Ignored Retry pending sync because another sync is running")
            return
        }
        isSyncing = true
        let historyId = appendHistoryEntry(trigger: .retryPending)
        recordDiagnosticEvent("Sync started: Retry pending")
        lastAttemptDate = .now
        lastError = nil
        lastBatchCount = 0
        saveSyncState()
        defer { Task { @MainActor in isSyncing = false } }

        do {
            let pending = try await queue.pendingBatches()
            var sent = 0
            for batch in pending.batches {
                try await uploadWithFallback(batch)
                await queue.dequeue(batchId: batch.batchId)
                sent += 1
            }
            lastBatchCount = sent
            if !pending.quarantinedFiles.isEmpty {
                lastError = queueWarning(for: pending.quarantinedFiles)
            } else if sent == 0 {
                lastError = "No readable pending batches to retry."
            }
            finishHistoryEntry(
                id: historyId,
                outcome: lastError == nil ? .succeeded : .failed,
                completedAt: .now,
                records: 0,
                deleted: 0,
                batches: sent,
                error: lastError
            )
        } catch {
            lastError = error.localizedDescription
            finishHistoryEntry(
                id: historyId,
                outcome: .failed,
                completedAt: .now,
                records: 0,
                deleted: 0,
                batches: lastBatchCount,
                error: lastError
            )
        }
        pendingCount = await queue.count()
        lastAttemptDate = .now
        saveSyncState()
    }

    // MARK: Background sync

    func scheduleBackgroundSync() {
        guard backgroundSyncEnabled else {
            recordDiagnosticEvent("Skipped BGAppRefreshTask scheduling because background sync is disabled")
            return
        }

        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundRefreshTaskIdentifier)

        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundRefreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.minimumBackgroundSyncInterval)

        do {
            try BGTaskScheduler.shared.submit(request)
            recordDiagnosticEvent("Scheduled BGAppRefreshTask earliest=\(request.earliestBeginDate?.formatted(date: .omitted, time: .standard) ?? "unknown")")
        } catch {
            log.error("Failed to schedule background sync: \(error.localizedDescription)")
            recordDiagnosticEvent("Failed to schedule BGAppRefreshTask: \(error.localizedDescription)")
        }
    }

    func configureBackgroundSync(typeGroups: [VitalsyncTypeGroup]) async {
        guard HealthKitManager.isHealthDataAvailable else {
            recordDiagnosticEvent("Skipped background sync configuration because Health data is unavailable")
            return
        }

        if backgroundSyncEnabled {
            let enabledIDs = typeGroups.filter(\.enabled).map(\.id).joined(separator: ",")
            recordDiagnosticEvent("Configuring HealthKit background delivery for \(enabledIDs.isEmpty ? "none" : enabledIDs)")
            await hkManager.configureBackgroundDelivery(groups: typeGroups) { [weak self] in
                self?.recordDiagnosticEvent("HealthKit observer callback received")
                await self?.performBackgroundSync(typeGroups: typeGroups, trigger: .backgroundHealthKit)
            }
            recordDiagnosticEvent("Configured HealthKit background delivery")
            scheduleBackgroundSync()
        } else {
            recordDiagnosticEvent("Disabling HealthKit background delivery and BGAppRefreshTask")
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundRefreshTaskIdentifier)
            await hkManager.disableBackgroundDelivery(groups: HealthKitManager.typeGroups)
        }
    }

    func performBackgroundSync(typeGroups: [VitalsyncTypeGroup], trigger: SyncTrigger = .backgroundRefresh) async {
        recordDiagnosticEvent("Background sync invoked: \(trigger.displayName)")
        guard backgroundSyncEnabled else {
            recordDiagnosticEvent("Ignored \(trigger.displayName) because background sync is disabled")
            return
        }
        defer { scheduleBackgroundSync() }

        await syncNow(typeGroups: typeGroups, trigger: trigger)
    }

    // MARK: Upload with fallback

    private func uploadWithFallback(_ batch: VitalsyncBatch) async throws {
        do {
            try await transport.uploadViaHTTPS(batch)
        } catch {
            if shouldQueueForRetry(error) {
                try await queue.enqueue(batch)
            }
            throw error
        }
    }

    private func shouldQueueForRetry(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled, .userAuthenticationRequired, .userCancelledAuthentication:
                return false
            default:
                return true
            }
        }

        guard let transportError = error as? TransportError else { return false }
        switch transportError {
        case .timeout, .streamError:
            return true
        case .httpError(let code, _):
            return code == 408 || code == 429 || code >= 500
        case .webTransportUnavailable, .sessionTokenFetchFailed:
            return false
        }
    }

    private func queueWarning(for filenames: [String]) -> String {
        let label = filenames.count == 1 ? "batch" : "batches"
        return "Skipped \(filenames.count) unreadable pending \(label). Run Sync now to re-query data that was never uploaded."
    }

    private func shouldDeferProtectedHealthDataError(_ error: Error, trigger: SyncTrigger) -> Bool {
        guard trigger == .backgroundHealthKit || trigger == .backgroundRefresh else { return false }

        let nsError = error as NSError
        if nsError.domain == HKError.errorDomain,
           nsError.code == HKError.Code.errorDatabaseInaccessible.rawValue {
            return true
        }

        return error.localizedDescription.localizedCaseInsensitiveContains("protected health data is inaccessible")
    }

    func resetSyncAnchors(typeGroups: [VitalsyncTypeGroup]) async {
        for group in typeGroups {
            await hkManager.resetAnchor(for: group)
        }
        lastSyncDate = nil
        lastAttemptDate = nil
        lastBatchCount = 0
        lastSuccessfulBatchCount = 0
        lastRecordCount = 0
        lastDeletedCount = 0
        lastError = nil
        syncStatus = nil
        pendingCount = await queue.count()
        saveSyncState()
    }

    private func loadSyncState() {
        let defaults = UserDefaults.standard
        lastSyncDate = defaults.object(forKey: Self.lastSyncDateKey) as? Date
        lastAttemptDate = defaults.object(forKey: Self.lastAttemptDateKey) as? Date
        lastError = defaults.string(forKey: Self.lastErrorKey)
        lastBatchCount = defaults.integer(forKey: Self.lastBatchCountKey)
        lastSuccessfulBatchCount = defaults.integer(forKey: Self.lastSuccessfulBatchCountKey)
        lastRecordCount = defaults.integer(forKey: Self.lastRecordCountKey)
        lastDeletedCount = defaults.integer(forKey: Self.lastDeletedCountKey)
        if let data = defaults.data(forKey: Self.syncHistoryKey),
           let entries = try? JSONDecoder.vitalsync.decode([SyncHistoryEntry].self, from: data) {
            syncHistory = entries
        }
        if let data = defaults.data(forKey: Self.diagnosticEventsKey),
           let entries = try? JSONDecoder.vitalsync.decode([SyncDiagnosticEvent].self, from: data) {
            diagnosticEvents = entries
        }
    }

    private func saveSyncState() {
        let defaults = UserDefaults.standard
        defaults.set(lastSyncDate, forKey: Self.lastSyncDateKey)
        defaults.set(lastAttemptDate, forKey: Self.lastAttemptDateKey)
        defaults.set(lastError, forKey: Self.lastErrorKey)
        defaults.set(lastBatchCount, forKey: Self.lastBatchCountKey)
        defaults.set(lastSuccessfulBatchCount, forKey: Self.lastSuccessfulBatchCountKey)
        defaults.set(lastRecordCount, forKey: Self.lastRecordCountKey)
        defaults.set(lastDeletedCount, forKey: Self.lastDeletedCountKey)
        if let data = try? JSONEncoder.vitalsync.encode(syncHistory) {
            defaults.set(data, forKey: Self.syncHistoryKey)
        }
        if let data = try? JSONEncoder.vitalsync.encode(diagnosticEvents) {
            defaults.set(data, forKey: Self.diagnosticEventsKey)
        }
    }

    func recordDiagnosticEvent(_ message: String) {
        log.info("\(message)")
        diagnosticEvents.insert(
            SyncDiagnosticEvent(id: UUID(), timestamp: .now, message: message),
            at: 0
        )
        if diagnosticEvents.count > Self.maxDiagnosticEvents {
            diagnosticEvents.removeLast(diagnosticEvents.count - Self.maxDiagnosticEvents)
        }
        saveSyncState()
    }

    private func appendHistoryEntry(trigger: SyncTrigger) -> UUID {
        let entry = SyncHistoryEntry(
            id: UUID(),
            trigger: trigger,
            startedAt: .now,
            completedAt: nil,
            outcome: .running,
            records: 0,
            deleted: 0,
            batches: 0,
            error: nil
        )
        syncHistory.insert(entry, at: 0)
        if syncHistory.count > Self.maxHistoryEntries {
            syncHistory.removeLast(syncHistory.count - Self.maxHistoryEntries)
        }
        saveSyncState()
        return entry.id
    }

    private func finishHistoryEntry(
        id: UUID,
        outcome: SyncOutcome,
        completedAt: Date,
        records: Int,
        deleted: Int,
        batches: Int,
        error: String?
    ) {
        guard let index = syncHistory.firstIndex(where: { $0.id == id }) else { return }
        syncHistory[index].completedAt = completedAt
        syncHistory[index].outcome = outcome
        syncHistory[index].records = records
        syncHistory[index].deleted = deleted
        syncHistory[index].batches = batches
        syncHistory[index].error = error
        saveSyncState()
    }

    // MARK: Batch splitting

    private func splitIntoBatches(
        records: [VitalsyncRecord],
        deleted: [VitalsyncTombstone]
    ) async throws -> [VitalsyncBatch] {
        guard let deviceId = credentials.deviceId else { throw SyncError.deviceNotRegistered }

        var batches: [VitalsyncBatch] = []
        var chunk: [VitalsyncRecord] = []
        var deletedChunk: [VitalsyncTombstone] = []
        var estimatedChunkBytes = try emptyBatchSize(deviceId: deviceId)
        let targetBatchBytes = Self.maxBatchBytes - 8_192

        func flush() throws {
            guard !chunk.isEmpty || !deletedChunk.isEmpty else { return }
            sequenceCounter += 1
            let batch = VitalsyncBatch.make(
                deviceId: deviceId,
                sequence: sequenceCounter,
                records: chunk,
                deleted: deletedChunk
            )
            let size = try JSONEncoder.vitalsync.encode(batch).count
            guard size <= Self.maxBatchBytes else { throw SyncError.batchTooLarge }
            batches.append(batch)
            chunk = []
            deletedChunk = []
            estimatedChunkBytes = try emptyBatchSize(deviceId: deviceId)
        }

        for (index, record) in records.enumerated() {
            let recordBytes = try JSONEncoder.vitalsync.encode(record).count
            let separatorBytes = chunk.isEmpty ? 0 : 1
            if estimatedChunkBytes + recordBytes + separatorBytes > targetBatchBytes {
                try flush()
                guard recordBytes + estimatedChunkBytes <= targetBatchBytes else {
                    throw SyncError.batchTooLarge
                }
            }
            chunk.append(record)
            estimatedChunkBytes += recordBytes + (chunk.count == 1 ? 0 : 1)
            if index.isMultiple(of: 1_000) {
                syncStatus = "Building batches: \(index + 1) of \(records.count) records, \(batches.count) ready"
                await Task.yield()
            }
        }

        for (index, tombstone) in deleted.enumerated() {
            let tombstoneBytes = try JSONEncoder.vitalsync.encode(tombstone).count
            let separatorBytes = deletedChunk.isEmpty ? 0 : 1
            if estimatedChunkBytes + tombstoneBytes + separatorBytes > targetBatchBytes {
                try flush()
                guard tombstoneBytes + estimatedChunkBytes <= targetBatchBytes else {
                    throw SyncError.batchTooLarge
                }
            }
            deletedChunk.append(tombstone)
            estimatedChunkBytes += tombstoneBytes + (deletedChunk.count == 1 ? 0 : 1)
            if index.isMultiple(of: 1_000) {
                syncStatus = "Building batches: \(records.count) records, \(index + 1) of \(deleted.count) deletions, \(batches.count) ready"
                await Task.yield()
            }
        }

        try flush()
        return batches
    }

    private func emptyBatchSize(deviceId: String) throws -> Int {
        let batch = VitalsyncBatch.make(
            deviceId: deviceId,
            sequence: sequenceCounter + 1,
            records: [],
            deleted: []
        )
        return try JSONEncoder.vitalsync.encode(batch).count
    }
}

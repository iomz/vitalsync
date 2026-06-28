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
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        log.info("Queued batch \(batch.batchId) (\(data.count) bytes)")
    }

    func pendingBatches() throws -> PendingBatchLoad {
        let files = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("pending-") }
        var batches: [VitalsyncBatch] = []
        var quarantinedFiles: [String] = []

        for url in files {
            let data = try Data(contentsOf: url)
            do {
                batches.append(try JSONDecoder.vitalsync.decode(VitalsyncBatch.self, from: data))
            } catch {
                let filename = url.lastPathComponent
                quarantinedFiles.append(filename)
                quarantineUnreadableBatch(at: url)
                log.error("Quarantined unreadable pending batch \(filename): \(error.localizedDescription)")
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

    private func quarantineUnreadableBatch(at url: URL) {
        let quarantinedName = "invalid-\(Int(Date().timeIntervalSince1970))-\(url.lastPathComponent)"
        let destination = dir.appendingPathComponent(quarantinedName)
        try? FileManager.default.moveItem(at: url, to: destination)
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
    private static let lastBackgroundSyncAttemptKey = "last_background_sync_attempt"
    private static let lastSyncDateKey = "last_sync_date"
    private static let lastAttemptDateKey = "last_attempt_date"
    private static let lastErrorKey = "last_error"
    private static let lastBatchCountKey = "last_batch_count"
    private static let lastSuccessfulBatchCountKey = "last_successful_batch_count"
    private static let lastRecordCountKey = "last_record_count"
    private static let lastDeletedCountKey = "last_deleted_count"
    private static let minimumBackgroundSyncInterval: TimeInterval = 6 * 60 * 60

    init(hkManager: HealthKitManager, transport: TransportManager, credentials: CredentialStore) {
        self.hkManager = hkManager
        self.transport = transport
        self.credentials = credentials
        backgroundSyncEnabled = UserDefaults.standard.bool(forKey: Self.backgroundSyncEnabledKey)
        loadSyncState()
        Task { pendingCount = await queue.count() }
    }

    // MARK: Manual sync

    func syncNow(typeGroups: [VitalsyncTypeGroup]) async {
        guard !isSyncing else { return }
        isSyncing = true
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
                    guard qr.rawSampleCount == qr.records.count else {
                        throw SyncError.unmappedHealthSamples(vitalsyncType, qr.rawSampleCount, qr.records.count)
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
            syncStatus = "Building batches"
            let batches = try await splitIntoBatches(records: allRecords, deleted: allDeleted)

            // 3. Upload each batch (retry pending first, then new)
            let pending = try await queue.pendingBatches()
            let uploadBatches = pending.batches + batches
            for (index, batch) in uploadBatches.enumerated() {
                syncStatus = "Uploading \(index + 1) of \(uploadBatches.count)"
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

        } catch {
            result.completedAt = .now
            lastAttemptDate = result.completedAt
            lastBatchCount = result.batchesSent
            lastError = error.localizedDescription
            log.error("Sync failed: \(error.localizedDescription)")
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
        guard !isSyncing else { return }
        isSyncing = true
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
            pendingCount = await queue.count()
            if !pending.quarantinedFiles.isEmpty {
                lastError = queueWarning(for: pending.quarantinedFiles)
            } else if sent == 0 {
                lastError = "No readable pending batches to retry."
            }
        } catch {
            lastError = error.localizedDescription
        }
        lastAttemptDate = .now
        saveSyncState()
    }

    // MARK: Background sync

    func scheduleBackgroundSync() {
        guard backgroundSyncEnabled else { return }

        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundRefreshTaskIdentifier)

        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundRefreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.minimumBackgroundSyncInterval)

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.error("Failed to schedule background sync: \(error.localizedDescription)")
        }
    }

    func configureBackgroundSync(typeGroups: [VitalsyncTypeGroup]) async {
        guard HealthKitManager.isHealthDataAvailable else { return }

        if backgroundSyncEnabled {
            await hkManager.configureBackgroundDelivery(groups: typeGroups) { [weak self] in
                await self?.performBackgroundSync(typeGroups: typeGroups)
            }
            scheduleBackgroundSync()
        } else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundRefreshTaskIdentifier)
            await hkManager.disableBackgroundDelivery(groups: HealthKitManager.typeGroups)
        }
    }

    func performBackgroundSync(typeGroups: [VitalsyncTypeGroup]) async {
        guard backgroundSyncEnabled else { return }
        defer { scheduleBackgroundSync() }

        if let lastAttempt = UserDefaults.standard.object(forKey: Self.lastBackgroundSyncAttemptKey) as? Date,
           Date().timeIntervalSince(lastAttempt) < Self.minimumBackgroundSyncInterval {
            log.info("Skipping background sync because the previous attempt was recent")
            return
        }

        UserDefaults.standard.set(Date(), forKey: Self.lastBackgroundSyncAttemptKey)
        await syncNow(typeGroups: typeGroups)
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

    func resetSyncHistory(typeGroups: [VitalsyncTypeGroup]) async {
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

        func encodedSize(records: [VitalsyncRecord], deleted: [VitalsyncTombstone]) throws -> Int {
            let batch = VitalsyncBatch.make(
                deviceId: deviceId,
                sequence: sequenceCounter + 1,
                records: records,
                deleted: deleted
            )
            return try JSONEncoder.vitalsync.encode(batch).count
        }

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
        }

        for (index, record) in records.enumerated() {
            let candidate = chunk + [record]
            if try encodedSize(records: candidate, deleted: deletedChunk) > Self.maxBatchBytes {
                try flush()
                guard try encodedSize(records: [record], deleted: []) <= Self.maxBatchBytes else {
                    throw SyncError.batchTooLarge
                }
            }
            chunk.append(record)
            if index.isMultiple(of: 5_000) {
                await Task.yield()
            }
        }

        for (index, tombstone) in deleted.enumerated() {
            let candidate = deletedChunk + [tombstone]
            if try encodedSize(records: chunk, deleted: candidate) > Self.maxBatchBytes {
                try flush()
                guard try encodedSize(records: [], deleted: [tombstone]) <= Self.maxBatchBytes else {
                    throw SyncError.batchTooLarge
                }
            }
            deletedChunk.append(tombstone)
            if index.isMultiple(of: 5_000) {
                await Task.yield()
            }
        }

        try flush()
        return batches
    }
}

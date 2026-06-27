import BackgroundTasks
import Foundation
import OSLog

private let log = Logger(subsystem: "io.sazanka.vitalsync", category: "SyncEngine")

// MARK: - Sync state

enum SyncError: LocalizedError {
    case deviceNotRegistered
    case batchTooLarge
    case serverRejected(ServerError)
    case transportUnavailable

    var errorDescription: String? {
        switch self {
        case .deviceNotRegistered:   return "Device not registered with receiver."
        case .batchTooLarge:         return "Batch too large even after split."
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

    func pendingBatches() throws -> [VitalsyncBatch] {
        let files = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("pending-") }
        return try files.compactMap { url -> VitalsyncBatch? in
            let data = try Data(contentsOf: url)
            return try? JSONDecoder.vitalsync.decode(VitalsyncBatch.self, from: data)
        }.sorted { $0.sequence < $1.sequence }
    }

    func dequeue(batchId: String) {
        let url = dir.appendingPathComponent("pending-\(batchId).json")
        try? FileManager.default.removeItem(at: url)
    }

    func count() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("pending-") }.count) ?? 0
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
    @Published var lastError: String?
    @Published var lastBatchCount: Int = 0
    @Published var pendingCount: Int = 0
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
    private static let minimumBackgroundSyncInterval: TimeInterval = 6 * 60 * 60

    init(hkManager: HealthKitManager, transport: TransportManager, credentials: CredentialStore) {
        self.hkManager = hkManager
        self.transport = transport
        self.credentials = credentials
        backgroundSyncEnabled = UserDefaults.standard.bool(forKey: Self.backgroundSyncEnabledKey)
    }

    // MARK: Manual sync

    func syncNow(typeGroups: [VitalsyncTypeGroup]) async {
        guard !isSyncing else { return }
        isSyncing = true
        lastError = nil
        var result = SyncResult()

        do {
            // 1. Query all enabled type groups incrementally
            var allRecords: [VitalsyncRecord] = []
            var allDeleted: [VitalsyncTombstone] = []

            for group in typeGroups where group.enabled {
                for hkType in group.queryTypes {
                    guard let vitalsyncType = hkManager.vitalsyncSampleType(for: hkType) else { continue }
                    let qr = try await hkManager.queryIncremental(sampleType: hkType, vitalsyncType: vitalsyncType)
                    allRecords.append(contentsOf: qr.records)
                    allDeleted.append(contentsOf: qr.tombstones)
                }
            }

            result.totalRecords = allRecords.count
            result.totalDeleted = allDeleted.count

            // 2. Split into batches ≤ 1 MiB, newest 30 days first
            let batches = try splitIntoBatches(records: allRecords, deleted: allDeleted)

            // 3. Upload each batch (retry pending first, then new)
            let pending = try await queue.pendingBatches()
            for batch in (pending + batches) {
                try await uploadWithFallback(batch)
                await queue.dequeue(batchId: batch.batchId)
                result.batchesSent += 1
            }

            lastSyncDate = .now
            lastBatchCount = result.batchesSent
            log.info("Sync complete: \(result.totalRecords) records, \(result.batchesSent) batches")

        } catch {
            lastError = error.localizedDescription
            log.error("Sync failed: \(error.localizedDescription)")
        }

        pendingCount = await queue.count()
        isSyncing = false
    }

    // MARK: Retry pending

    func retryPending() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { Task { @MainActor in isSyncing = false } }

        do {
            let pending = try await queue.pendingBatches()
            for batch in pending {
                try await uploadWithFallback(batch)
                await queue.dequeue(batchId: batch.batchId)
            }
            pendingCount = await queue.count()
        } catch {
            lastError = error.localizedDescription
        }
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
            _ = try await transport.uploadViaWebTransport(batch)
        } catch TransportError.webTransportUnavailable {
            log.info("WebTransport unavailable, falling back to HTTPS for batch \(batch.batchId)")
            try await transport.uploadViaHTTPS(batch)
        } catch {
            // Enqueue for later retry
            try await queue.enqueue(batch)
            throw error
        }
    }

    // MARK: Batch splitting

    private func splitIntoBatches(
        records: [VitalsyncRecord],
        deleted: [VitalsyncTombstone]
    ) throws -> [VitalsyncBatch] {
        guard let deviceId = credentials.deviceId else { throw SyncError.deviceNotRegistered }

        var batches: [VitalsyncBatch] = []
        var chunk: [VitalsyncRecord] = []
        var deletedChunk: [VitalsyncTombstone] = []

        func flush() throws {
            guard !chunk.isEmpty || !deletedChunk.isEmpty else { return }
            sequenceCounter += 1
            let batch = VitalsyncBatch.make(
                deviceId: deviceId,
                sequence: sequenceCounter,
                records: chunk,
                deleted: deletedChunk
            )
            let size = (try? JSONEncoder.vitalsync.encode(batch).count) ?? 0
            guard size <= Self.maxBatchBytes else { throw SyncError.batchTooLarge }
            batches.append(batch)
            chunk = []
            deletedChunk = []
        }

        for record in records {
            chunk.append(record)
            let probe = VitalsyncBatch.make(deviceId: deviceId, sequence: 0, records: chunk, deleted: [])
            if let sz = try? JSONEncoder.vitalsync.encode(probe).count, sz > Self.maxBatchBytes {
                chunk.removeLast()
                try flush()
                chunk.append(record)
            }
        }
        deletedChunk = deleted
        try flush()
        return batches
    }
}

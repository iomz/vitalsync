import HealthKit
import OSLog

private let log = Logger(subsystem: "io.sazanka.vitalsync", category: "HealthKit")

// MARK: - Type group definition

struct VitalsyncTypeGroup: Identifiable {
    let id: String
    let displayName: String
    let authorizationTypes: [HKObjectType]
    let queryTypes: [HKSampleType]
    var enabled: Bool

    init(
        id: String,
        displayName: String,
        authorizationTypes: [HKObjectType],
        queryTypes: [HKSampleType],
        enabled: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.authorizationTypes = authorizationTypes
        self.queryTypes = queryTypes
        self.enabled = enabled
    }

    init(id: String, displayName: String, sampleTypes: [HKSampleType], enabled: Bool) {
        self.init(
            id: id,
            displayName: displayName,
            authorizationTypes: sampleTypes.map { $0 as HKObjectType },
            queryTypes: sampleTypes,
            enabled: enabled
        )
    }
}

// MARK: - Anchor store (persisted per sample type)

actor AnchorStore {
    private let dir: URL

    init() {
        let app = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        dir = app.appendingPathComponent("anchors", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func load(for key: String) -> HKQueryAnchor? {
        let url = dir.appendingPathComponent("\(key).anchor")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    func save(_ anchor: HKQueryAnchor, for key: String) {
        let url = dir.appendingPathComponent("\(key).anchor")
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func reset(for key: String) {
        let url = dir.appendingPathComponent("\(key).anchor")
        try? FileManager.default.removeItem(at: url)
    }
}

actor StepSampleDayStore {
    enum LoadError: Error {
        case unreadableIndex(Error)
    }

    private let url: URL
    private var cached: [String: String]?

    init() {
        let app = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        url = app.appendingPathComponent("daily-step-sample-days.json")
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    func days(for sourceIds: [String], calendar: Calendar) -> Set<Date> {
        guard let index = try? load() else { return [] }
        return Set(sourceIds.compactMap { sourceId in
            index[sourceId].flatMap(Self.dayFormatter.date(from:)).map { calendar.startOfDay(for: $0) }
        })
    }

    func save(records: [VitalsyncRecord], calendar: Calendar) {
        guard !records.isEmpty else { return }
        guard var index = try? load() else { return }
        for record in records {
            index[record.sourceId] = Self.dayFormatter.string(from: calendar.startOfDay(for: record.startTime))
        }
        persist(index)
    }

    func remove(sourceIds: [String]) {
        guard !sourceIds.isEmpty else { return }
        guard var index = try? load() else { return }
        for sourceId in sourceIds {
            index.removeValue(forKey: sourceId)
        }
        persist(index)
    }

    private func load() throws -> [String: String] {
        if let cached { return cached }
        guard FileManager.default.fileExists(atPath: url.path) else {
            cached = [:]
            return [:]
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            log.error("Could not read daily step sample day index: \(error.localizedDescription)")
            throw LoadError.unreadableIndex(error)
        }
        guard let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            cached = [:]
            return [:]
        }
        cached = decoded
        return decoded
    }

    private func persist(_ index: [String: String]) {
        cached = index
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    private nonisolated static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

// MARK: - Query result

struct VitalsyncQueryResult {
    let sampleType: VitalsyncSampleType
    let records: [VitalsyncRecord]
    let tombstones: [VitalsyncTombstone]
    let rawSampleCount: Int
    let mappedSampleCount: Int
    let rawDeletedCount: Int
    let newAnchor: HKQueryAnchor?
}

// MARK: - HealthKitManager

@MainActor
final class HealthKitManager: ObservableObject {
    private let store = HKHealthStore()
    private let anchors = AnchorStore()
    private let stepSampleDays = StepSampleDayStore()
    private var observerQueries: [String: HKObserverQuery] = [:]

    @Published var authorizationStatus: [String: HKAuthorizationStatus] = [:]
    @Published var readAuthorizationRequestStatus: [String: HKAuthorizationRequestStatus] = [:]
    static var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: Type groups

    static let typeGroups: [VitalsyncTypeGroup] = [
        VitalsyncTypeGroup(id: "sleep", displayName: "Sleep", sampleTypes: [
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        ], enabled: true),
        VitalsyncTypeGroup(id: "activity", displayName: "Activity", sampleTypes: [
            HKObjectType.quantityType(forIdentifier: .stepCount)!,
            HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)!,
            HKObjectType.quantityType(forIdentifier: .flightsClimbed)!,
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
            HKObjectType.quantityType(forIdentifier: .basalEnergyBurned)!,
            HKObjectType.quantityType(forIdentifier: .appleExerciseTime)!,
            HKObjectType.quantityType(forIdentifier: .appleStandTime)!,
        ], enabled: true),
        VitalsyncTypeGroup(id: "body", displayName: "Body", sampleTypes: [
            HKObjectType.quantityType(forIdentifier: .bodyMass)!,
            HKObjectType.quantityType(forIdentifier: .bodyFatPercentage)!,
            HKObjectType.quantityType(forIdentifier: .leanBodyMass)!,
            HKObjectType.quantityType(forIdentifier: .height)!,
        ], enabled: true),
        VitalsyncTypeGroup(id: "vitals", displayName: "Vitals", sampleTypes: [
            HKObjectType.quantityType(forIdentifier: .heartRate)!,
            HKObjectType.quantityType(forIdentifier: .restingHeartRate)!,
            HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
            HKObjectType.quantityType(forIdentifier: .respiratoryRate)!,
            HKObjectType.quantityType(forIdentifier: .oxygenSaturation)!,
            HKObjectType.quantityType(forIdentifier: .bodyTemperature)!,
        ], enabled: true),
        VitalsyncTypeGroup(id: "bloodpressure", displayName: "Blood Pressure", authorizationTypes: [
            HKQuantityType(.bloodPressureSystolic),
            HKQuantityType(.bloodPressureDiastolic),
        ], queryTypes: [
            HKCorrelationType(.bloodPressure),
        ], enabled: true),
    ]

    // MARK: Request permissions

    func authorizationRequestStatus(groups: [VitalsyncTypeGroup]) async throws -> HKAuthorizationRequestStatus {
        let readTypes = authorizationReadTypes(for: groups)
        return try await withCheckedThrowingContinuation { cont in
            store.getRequestStatusForAuthorization(toShare: [], read: readTypes) { status, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: status)
                }
            }
        }
    }

    func requestAuthorization(groups: [VitalsyncTypeGroup]) async throws {
        let enabled = groups.filter(\.enabled)
        let readTypes = authorizationReadTypes(for: enabled)
        try await store.requestAuthorization(toShare: [], read: readTypes)
        refreshAuthorizationStatus(for: enabled)
        await refreshReadAuthorizationStatus(for: groups)
    }

    private func authorizationReadTypes(for groups: [VitalsyncTypeGroup]) -> Set<HKObjectType> {
        Set(groups.filter(\.enabled).flatMap(\.authorizationTypes))
    }

    func refreshAuthorizationStatus(for groups: [VitalsyncTypeGroup]) {
        var status: [String: HKAuthorizationStatus] = [:]
        for group in groups {
            for type in group.authorizationTypes {
                status[group.id] = store.authorizationStatus(for: type)
            }
        }
        authorizationStatus = status
    }

    func refreshReadAuthorizationStatus(for groups: [VitalsyncTypeGroup]) async {
        var status: [String: HKAuthorizationRequestStatus] = [:]
        for group in groups {
            guard !authorizationReadTypes(for: [group]).isEmpty else { continue }
            do {
                status[group.id] = try await authorizationRequestStatus(groups: [group])
            } catch {
                status[group.id] = .unknown
            }
        }
        readAuthorizationRequestStatus = status
    }

    func enabledGroupsHaveDeniedStatus(_ groups: [VitalsyncTypeGroup]) -> Bool {
        groups
            .filter(\.enabled)
            .contains { authorizationStatus[$0.id] == .sharingDenied }
    }

    // MARK: Background delivery

    func configureBackgroundDelivery(
        groups: [VitalsyncTypeGroup],
        onUpdate: @escaping @MainActor () async -> Void
    ) async {
        let allTypesByKey = Dictionary(
            groups.flatMap(\.queryTypes).map { (backgroundDeliveryKey(for: $0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let activeTypes = groups.filter(\.enabled).flatMap(\.queryTypes)
        let activeKeys = Set(activeTypes.map(backgroundDeliveryKey(for:)))

        for (key, type) in allTypesByKey where !activeKeys.contains(key) {
            if let query = observerQueries.removeValue(forKey: key) {
                store.stop(query)
            }
            do {
                try await disableBackgroundDelivery(for: type)
            } catch {
                log.error("Failed to disable HealthKit background delivery for \(key): \(error.localizedDescription)")
            }
        }

        for type in activeTypes {
            let key = backgroundDeliveryKey(for: type)
            if let query = observerQueries.removeValue(forKey: key) {
                store.stop(query)
            }
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completionHandler, error in
                if let error {
                    log.error("HealthKit observer update failed for \(key): \(error.localizedDescription)")
                    completionHandler()
                    return
                }

                Task { @MainActor in
                    await onUpdate()
                    completionHandler()
                }
            }
            observerQueries[key] = query
            store.execute(query)

            do {
                try await enableBackgroundDelivery(for: type)
            } catch {
                log.error("Failed to enable HealthKit background delivery for \(key): \(error.localizedDescription)")
            }
        }
    }

    func disableBackgroundDelivery(groups: [VitalsyncTypeGroup]) async {
        for query in observerQueries.values {
            store.stop(query)
        }
        observerQueries.removeAll()

        for type in groups.flatMap(\.queryTypes) {
            do {
                try await disableBackgroundDelivery(for: type)
            } catch {
                log.error("Failed to disable HealthKit background delivery for \(self.backgroundDeliveryKey(for: type)): \(error.localizedDescription)")
            }
        }
    }

    private func enableBackgroundDelivery(for type: HKSampleType) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            store.enableBackgroundDelivery(for: type, frequency: .immediate) { success, error in
                if let error {
                    cont.resume(throwing: error)
                } else if success {
                    cont.resume()
                } else {
                    cont.resume(throwing: SyncError.healthAuthorizationNotDetermined)
                }
            }
        }
    }

    private func disableBackgroundDelivery(for type: HKSampleType) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            store.disableBackgroundDelivery(for: type) { success, error in
                if let error {
                    cont.resume(throwing: error)
                } else if success {
                    cont.resume()
                } else {
                    cont.resume(throwing: SyncError.healthAuthorizationNotDetermined)
                }
            }
        }
    }

    private func backgroundDeliveryKey(for type: HKSampleType) -> String {
        type.identifier
    }

    // MARK: Anchored query (incremental sync)

    func queryIncremental(
        sampleType: HKSampleType,
        vitalsyncType: VitalsyncSampleType
    ) async throws -> VitalsyncQueryResult {
        let anchorKey = vitalsyncType.rawValue
        let savedAnchor = await anchors.load(for: anchorKey)

        let result = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<VitalsyncQueryResult, Error>) in
            let query = HKAnchoredObjectQuery(
                type: sampleType,
                predicate: nil,
                anchor: savedAnchor,
                limit: HKObjectQueryNoLimit
            ) { [weak self] _, samples, deleted, newAnchor, error in
                guard let self else { return }
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                let rawSamples = samples ?? []
                let rawDeleted = deleted ?? []
                let records = rawSamples.compactMap {
                    self.mapSample($0, to: vitalsyncType)
                }
                let tombstones = rawDeleted.map {
                    VitalsyncTombstone(
                        source: "apple_health",
                        sourceId: $0.uuid.uuidString,
                        sampleType: vitalsyncType,
                        deletedAt: Date()
                    )
                }
                log.info("Queried \(vitalsyncType.rawValue): \(records.count) records from \(rawSamples.count) samples, \(tombstones.count) tombstones from \(rawDeleted.count) deletes")
                cont.resume(returning: VitalsyncQueryResult(
                    sampleType: vitalsyncType,
                    records: records,
                    tombstones: tombstones,
                    rawSampleCount: rawSamples.count,
                    mappedSampleCount: records.count,
                    rawDeletedCount: rawDeleted.count,
                    newAnchor: newAnchor
                ))
            }
            store.execute(query)
        }

        guard vitalsyncType == .stepCount,
              let quantityType = sampleType as? HKQuantityType
        else {
            return result
        }

        let calendar = Calendar.current
        let deletedSourceIds = result.tombstones.map(\.sourceId)
        var touchedDays = Set(result.records.map { calendar.startOfDay(for: $0.startTime) })
        let deletedDays = await stepSampleDays.days(for: deletedSourceIds, calendar: calendar)
        touchedDays.formUnion(deletedDays)

        await stepSampleDays.remove(sourceIds: deletedSourceIds)
        await stepSampleDays.save(records: result.records, calendar: calendar)

        let dailyRecords = try await queryDailyStepCountRecords(
            quantityType: quantityType,
            touchedDays: touchedDays,
            repairRecentDays: result.rawDeletedCount > deletedDays.count || result.records.isEmpty
        )
        guard !dailyRecords.isEmpty else { return result }

        log.info("Added \(dailyRecords.count) daily step records")
        return VitalsyncQueryResult(
            sampleType: result.sampleType,
            records: result.records + dailyRecords,
            tombstones: result.tombstones,
            rawSampleCount: result.rawSampleCount,
            mappedSampleCount: result.mappedSampleCount,
            rawDeletedCount: result.rawDeletedCount,
            newAnchor: result.newAnchor
        )
    }

    func commitAnchor(for result: VitalsyncQueryResult) async {
        guard let newAnchor = result.newAnchor else { return }
        await anchors.save(newAnchor, for: result.sampleType.rawValue)
    }

    // MARK: Debug anchor reset

    func resetAnchor(for group: VitalsyncTypeGroup) async {
        for type in group.queryTypes {
            if let vitalsyncType = vitalsyncSampleType(for: type) {
                await anchors.reset(for: vitalsyncType.rawValue)
                log.warning("Anchor reset for \(vitalsyncType.rawValue) — full resync will occur")
            }
        }
    }

    // MARK: Sample → VitalsyncRecord mapping

    private func queryDailyStepCountRecords(
        quantityType: HKQuantityType,
        touchedDays: Set<Date>,
        repairRecentDays: Bool
    ) async throws -> [VitalsyncRecord] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var dayStarts = touchedDays

        if repairRecentDays {
            for offset in 0...30 {
                if let day = calendar.date(byAdding: .day, value: -offset, to: today) {
                    dayStarts.insert(day)
                }
            }
        }

        guard let firstDay = dayStarts.min(),
              let lastDay = dayStarts.max(),
              let queryEnd = calendar.date(byAdding: .day, value: 1, to: lastDay)
        else {
            return []
        }

        let queryStart = firstDay
        let targetDayStarts = dayStarts
        let sourceIdPrefix = dailyStepSourceIdPrefix()
        let dateFormatter = dailyStepDateFormatter()
        var interval = DateComponents()
        interval.day = 1

        return try await withCheckedThrowingContinuation { cont in
            let query = HKStatisticsCollectionQuery(
                quantityType: quantityType,
                quantitySamplePredicate: nil,
                options: .cumulativeSum,
                anchorDate: queryStart,
                intervalComponents: interval
            )

            query.initialResultsHandler = { _, collection, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                guard let collection else {
                    cont.resume(returning: [])
                    return
                }

                var quantitiesByDay: [Date: Double] = [:]
                collection.enumerateStatistics(from: queryStart, to: queryEnd) { statistics, _ in
                    let start = calendar.startOfDay(for: statistics.startDate)
                    guard targetDayStarts.contains(start) else { return }
                    quantitiesByDay[start] = statistics.sumQuantity()?.doubleValue(for: .count()) ?? 0
                }

                let records = targetDayStarts.sorted().compactMap { start -> VitalsyncRecord? in
                    guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
                    let day = dateFormatter.string(from: start)

                    return VitalsyncRecord(
                        schema: VitalsyncSchema.record,
                        source: "apple_health_daily",
                        sourceId: "\(sourceIdPrefix)_\(day)",
                        sampleType: .dailyStepCount,
                        sourceBundleId: nil,
                        sourceName: "Apple Health Daily Steps",
                        startTime: start,
                        endTime: end,
                        timezone: TimeZone.current.identifier,
                        value: .quantity(.init(quantity: quantitiesByDay[start] ?? 0)),
                        unit: "count",
                        metadata: [
                            "aggregate": "day",
                            "date": day,
                        ]
                    )
                }
                cont.resume(returning: records)
            }

            store.execute(query)
        }
    }

    private func dailyStepSourceIdPrefix() -> String {
        let credentials = CredentialStore.shared
        if let existing = credentials.dailyStepSourceIdPrefix, !existing.isEmpty {
            return existing
        }
        let created = "daily_step_count_\(UUID().uuidString)"
        credentials.dailyStepSourceIdPrefix = created
        return created
    }

    private func dailyStepDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    nonisolated private func mapSample(_ sample: HKSample, to type: VitalsyncSampleType) -> VitalsyncRecord? {
        let source = sample.sourceRevision.source
        let tz = (sample.metadata?[HKMetadataKeyTimeZone] as? String) ?? TimeZone.current.identifier

        let value: VitalsyncValue?
        var unit: String? = nil

        switch sample {
        case let s as HKCategorySample where type == .sleepAnalysis:
            let cat = sleepCategoryString(s.value)
            value = .sleep(.init(category: cat, rawValue: s.value))

        case let s as HKQuantitySample:
            let (qty, u) = quantityAndUnit(s, type: type)
            value = .quantity(.init(quantity: qty))
            unit = u

        case let s as HKWorkout:
            value = .workout(.init(
                activityType: s.workoutActivityType.name,
                durationSeconds: s.duration,
                totalEnergyBurned: s.totalEnergyBurned?.doubleValue(for: .kilocalorie()),
                totalDistance: s.totalDistance?.doubleValue(for: .meter())
            ))

        case let s as HKCorrelation where type == .bloodPressure:
            guard
                let sys = s.objects(for: HKObjectType.quantityType(forIdentifier: .bloodPressureSystolic)!).first as? HKQuantitySample,
                let dia = s.objects(for: HKObjectType.quantityType(forIdentifier: .bloodPressureDiastolic)!).first as? HKQuantitySample
            else { return nil }
            value = .bloodPressure(.init(
                systolic: sys.quantity.doubleValue(for: HKUnit.millimeterOfMercury()),
                diastolic: dia.quantity.doubleValue(for: HKUnit.millimeterOfMercury()),
                correlationId: s.uuid.uuidString
            ))
            unit = "mmHg"

        default:
            return nil
        }

        guard let value else { return nil }

        return VitalsyncRecord(
            schema: VitalsyncSchema.record,
            source: "apple_health",
            sourceId: sample.uuid.uuidString,
            sampleType: type,
            sourceBundleId: source.bundleIdentifier,
            sourceName: source.name,
            startTime: sample.startDate,
            endTime: sample.endDate,
            timezone: tz,
            value: value,
            unit: unit,
            metadata: [:]   // extend as needed; never include raw values in logs
        )
    }

    nonisolated private func sleepCategoryString(_ raw: Int) -> String {
        switch HKCategoryValueSleepAnalysis(rawValue: raw) {
        case .inBed:             return "in_bed"
        case .asleepUnspecified: return "asleep_unspecified"
        case .asleepCore:        return "asleep_core"
        case .asleepDeep:        return "asleep_deep"
        case .asleepREM:         return "asleep_rem"
        case .awake:             return "awake"
        default:                 return "unknown"
        }
    }

    nonisolated private func quantityAndUnit(_ s: HKQuantitySample, type: VitalsyncSampleType) -> (Double, String) {
        switch type {
        case .stepCount, .flightsClimbed:
            return (s.quantity.doubleValue(for: .count()), "count")
        case .walkingRunningDistance:
            return (s.quantity.doubleValue(for: .meter()), "m")
        case .activeEnergyBurned, .basalEnergyBurned:
            return (s.quantity.doubleValue(for: .kilocalorie()), "kcal")
        case .exerciseTime, .standTime:
            return (s.quantity.doubleValue(for: .minute()), "min")
        case .bodyMass, .leanBodyMass:
            return (s.quantity.doubleValue(for: .gramUnit(with: .kilo)), "kg")
        case .bodyFatPercentage:
            return (s.quantity.doubleValue(for: .percent()), "%")
        case .height:
            return (s.quantity.doubleValue(for: .meter()), "m")
        case .heartRate, .restingHeartRate:
            return (s.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())), "count/min")
        case .heartRateVariabilitySDNN:
            return (s.quantity.doubleValue(for: .secondUnit(with: .milli)), "ms")
        case .respiratoryRate:
            return (s.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())), "count/min")
        case .oxygenSaturation:
            return (s.quantity.doubleValue(for: .percent()), "%")
        case .bodyTemperature:
            return (s.quantity.doubleValue(for: .degreeCelsius()), "degC")
        default:
            return (s.quantity.doubleValue(for: .count()), "count")
        }
    }

    func vitalsyncSampleType(for type: HKSampleType) -> VitalsyncSampleType? {
        switch type {
        case HKObjectType.categoryType(forIdentifier: .sleepAnalysis):    return .sleepAnalysis
        case HKObjectType.quantityType(forIdentifier: .stepCount):         return .stepCount
        case HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning): return .walkingRunningDistance
        case HKObjectType.quantityType(forIdentifier: .flightsClimbed):   return .flightsClimbed
        case HKObjectType.quantityType(forIdentifier: .activeEnergyBurned): return .activeEnergyBurned
        case HKObjectType.quantityType(forIdentifier: .basalEnergyBurned): return .basalEnergyBurned
        case HKObjectType.quantityType(forIdentifier: .appleExerciseTime): return .exerciseTime
        case HKObjectType.quantityType(forIdentifier: .appleStandTime):   return .standTime
        case HKObjectType.quantityType(forIdentifier: .bodyMass):          return .bodyMass
        case HKObjectType.quantityType(forIdentifier: .bodyFatPercentage): return .bodyFatPercentage
        case HKObjectType.quantityType(forIdentifier: .leanBodyMass):     return .leanBodyMass
        case HKObjectType.quantityType(forIdentifier: .height):            return .height
        case HKObjectType.quantityType(forIdentifier: .heartRate):         return .heartRate
        case HKObjectType.quantityType(forIdentifier: .restingHeartRate): return .restingHeartRate
        case HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN): return .heartRateVariabilitySDNN
        case HKObjectType.quantityType(forIdentifier: .respiratoryRate):  return .respiratoryRate
        case HKObjectType.quantityType(forIdentifier: .oxygenSaturation): return .oxygenSaturation
        case HKObjectType.quantityType(forIdentifier: .bodyTemperature):  return .bodyTemperature
        case HKObjectType.correlationType(forIdentifier: .bloodPressure): return .bloodPressure
        case HKObjectType.workoutType():                                    return .workout
        default: return nil
        }
    }
}

// MARK: - HKWorkoutActivityType name helper

extension HKWorkoutActivityType {
    var name: String {
        switch self {
        case .running:      return "running"
        case .cycling:      return "cycling"
        case .walking:      return "walking"
        case .swimming:     return "swimming"
        case .yoga:         return "yoga"
        case .functionalStrengthTraining: return "strength_training"
        default:            return "other_\(rawValue)"
        }
    }
}

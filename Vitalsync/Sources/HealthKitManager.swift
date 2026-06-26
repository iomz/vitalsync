import HealthKit
import OSLog

private let log = Logger(subsystem: "io.sazanka.vitalsync", category: "HealthKit")

// MARK: - Type group definition

struct VitalsyncTypeGroup: Identifiable {
    let id: String
    let displayName: String
    let sampleTypes: [HKSampleType]
    var enabled: Bool
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

// MARK: - Query result

struct VitalsyncQueryResult {
    let sampleType: VitalsyncSampleType
    let records: [VitalsyncRecord]
    let tombstones: [VitalsyncTombstone]
}

// MARK: - HealthKitManager

@MainActor
final class HealthKitManager: ObservableObject {
    private let store = HKHealthStore()
    private let anchors = AnchorStore()

    @Published var authorizationStatus: [String: HKAuthorizationStatus] = [:]

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
        VitalsyncTypeGroup(id: "bloodpressure", displayName: "Blood Pressure", sampleTypes: [
            HKObjectType.correlationType(forIdentifier: .bloodPressure)!,
        ], enabled: true),
    ]

    // MARK: Request permissions

    func requestAuthorization(groups: [VitalsyncTypeGroup]) async throws {
        let enabled = groups.filter(\.enabled)
        let readTypes = Set(enabled.flatMap(\.sampleTypes))
        try await store.requestAuthorization(toShare: [], read: readTypes)
        refreshAuthStatus(for: enabled)
    }

    private func refreshAuthStatus(for groups: [VitalsyncTypeGroup]) {
        var status: [String: HKAuthorizationStatus] = [:]
        for group in groups {
            for type in group.sampleTypes {
                status[group.id] = store.authorizationStatus(for: type)
            }
        }
        authorizationStatus = status
    }

    // MARK: Anchored query (incremental sync)

    func queryIncremental(
        sampleType: HKSampleType,
        vitalsyncType: VitalsyncSampleType
    ) async throws -> VitalsyncQueryResult {
        let anchorKey = vitalsyncType.rawValue
        let savedAnchor = await anchors.load(for: anchorKey)

        return try await withCheckedThrowingContinuation { cont in
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
                Task {
                    if let newAnchor {
                        await self.anchors.save(newAnchor, for: anchorKey)
                    }
                    let records = (samples ?? []).compactMap {
                        self.mapSample($0, to: vitalsyncType)
                    }
                    let tombstones = (deleted ?? []).map {
                        VitalsyncTombstone(
                            source: "apple_health",
                            sourceId: $0.uuid.uuidString,
                            sampleType: vitalsyncType,
                            deletedAt: Date()
                        )
                    }
                    // Log counts only — never log raw values
                    log.info("Queried \(vitalsyncType.rawValue): \(records.count) records, \(tombstones.count) tombstones")
                    cont.resume(returning: VitalsyncQueryResult(
                        sampleType: vitalsyncType,
                        records: records,
                        tombstones: tombstones
                    ))
                }
            }
            store.execute(query)
        }
    }

    // MARK: Debug anchor reset

    func resetAnchor(for group: VitalsyncTypeGroup) async {
        for type in group.sampleTypes {
            if let vitalsyncType = vitalsyncSampleType(for: type) {
                await anchors.reset(for: vitalsyncType.rawValue)
                log.warning("Anchor reset for \(vitalsyncType.rawValue) — full resync will occur")
            }
        }
    }

    // MARK: Sample → VitalsyncRecord mapping

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

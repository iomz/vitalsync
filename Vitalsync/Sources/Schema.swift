import Foundation

enum VitalsyncSchema {
    static let control = "vitalsync.control.v1"
    static let batch = "vitalsync.batch.v1"
    static let batches = "vitalsync.batches.v1"
    static let deviceRegistration = "vitalsync.device_registration.v1"
    static let record = "vitalsync.record.v1"
    static let records = "vitalsync.records.v1"
}

// MARK: - Batch envelope

struct VitalsyncBatch: Codable {
    let schema: String
    let batchId: String
    let deviceId: String
    let createdAt: Date
    let timezone: String
    let sequence: Int
    var records: [VitalsyncRecord]
    var deleted: [VitalsyncTombstone]

    enum CodingKeys: String, CodingKey {
        case schema, batchId = "batch_id", deviceId = "device_id"
        case createdAt = "created_at", timezone, sequence, records, deleted
    }

    static func make(deviceId: String, sequence: Int, records: [VitalsyncRecord], deleted: [VitalsyncTombstone]) -> VitalsyncBatch {
        VitalsyncBatch(
            schema: VitalsyncSchema.batch,
            batchId: "batch_\(UUID().uuidString)",
            deviceId: deviceId,
            createdAt: Date(),
            timezone: TimeZone.current.identifier,
            sequence: sequence,
            records: records,
            deleted: deleted
        )
    }
}

// MARK: - Record

struct VitalsyncRecord: Codable {
    let schema: String
    let source: String
    let sourceId: String
    let sampleType: VitalsyncSampleType
    let sourceBundleId: String?
    let sourceName: String?
    let startTime: Date
    let endTime: Date
    let timezone: String
    let value: VitalsyncValue
    let unit: String?
    let metadata: [String: String]

    enum CodingKeys: String, CodingKey {
        case schema, source
        case sourceId = "source_id"
        case sampleType = "sample_type"
        case sourceBundleId = "source_bundle_id"
        case sourceName = "source_name"
        case startTime = "start_time"
        case endTime = "end_time"
        case timezone, value, unit, metadata
    }
}

// MARK: - Tombstone

struct VitalsyncTombstone: Codable {
    let source: String
    let sourceId: String
    let sampleType: VitalsyncSampleType
    let deletedAt: Date

    enum CodingKeys: String, CodingKey {
        case source
        case sourceId = "source_id"
        case sampleType = "sample_type"
        case deletedAt = "deleted_at"
    }
}

// MARK: - Sample types

enum VitalsyncSampleType: String, Codable {
    case sleepAnalysis = "sleep_analysis"
    case stepCount = "step_count"
    case dailyStepCount = "daily_step_count"
    case walkingRunningDistance = "walking_running_distance"
    case flightsClimbed = "flights_climbed"
    case activeEnergyBurned = "active_energy_burned"
    case basalEnergyBurned = "basal_energy_burned"
    case exerciseTime = "exercise_time"
    case standTime = "stand_time"
    case bodyMass = "body_mass"
    case bodyFatPercentage = "body_fat_percentage"
    case leanBodyMass = "lean_body_mass"
    case waistCircumference = "waist_circumference"
    case height
    case heartRate = "heart_rate"
    case restingHeartRate = "resting_heart_rate"
    case heartRateVariabilitySDNN = "heart_rate_variability_sdnn"
    case respiratoryRate = "respiratory_rate"
    case oxygenSaturation = "oxygen_saturation"
    case bodyTemperature = "body_temperature"
    case bloodPressure = "blood_pressure"
    case bloodPressureSystolic = "blood_pressure_systolic"
    case bloodPressureDiastolic = "blood_pressure_diastolic"
    case workout
}

// MARK: - Value union

enum VitalsyncValue: Codable {
    case sleep(SleepValue)
    case quantity(QuantityValue)
    case bloodPressure(BloodPressureValue)
    case workout(WorkoutValue)

    struct SleepValue: Codable {
        let category: String   // "asleep_core" | "asleep_deep" | "asleep_rem" | "in_bed" | "awake" etc.
        let rawValue: Int
        enum CodingKeys: String, CodingKey { case category, rawValue = "raw_value" }
    }

    struct QuantityValue: Codable {
        let quantity: Double
    }

    struct BloodPressureValue: Codable {
        let systolic: Double
        let diastolic: Double
        let correlationId: String?
        enum CodingKeys: String, CodingKey {
            case systolic, diastolic, correlationId = "correlation_id"
        }
    }

    struct WorkoutValue: Codable {
        let activityType: String
        let durationSeconds: Double
        let totalEnergyBurned: Double?
        let totalDistance: Double?
        enum CodingKeys: String, CodingKey {
            case activityType = "activity_type"
            case durationSeconds = "duration_seconds"
            case totalEnergyBurned = "total_energy_burned"
            case totalDistance = "total_distance"
        }
    }

    // Custom coding to encode/decode the inner struct directly (no type discriminator in JSON)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(SleepValue.self)         { self = .sleep(v);         return }
        if let v = try? c.decode(BloodPressureValue.self)  { self = .bloodPressure(v); return }
        if let v = try? c.decode(WorkoutValue.self)        { self = .workout(v);        return }
        if let v = try? c.decode(QuantityValue.self)       { self = .quantity(v);       return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown VitalsyncValue shape")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .sleep(let v):         try c.encode(v)
        case .quantity(let v):      try c.encode(v)
        case .bloodPressure(let v): try c.encode(v)
        case .workout(let v):       try c.encode(v)
        }
    }
}

// MARK: - Server responses

struct BatchAck: Codable {
    let batchId: String
    let accepted: Int
    let deleted: Int
    let duplicate: Bool
    enum CodingKeys: String, CodingKey {
        case batchId = "batch_id", accepted, deleted, duplicate
    }
}

struct ServerError: Codable, Error {
    let type: String
    let code: String
    let message: String
    let retryable: Bool
}

struct RegisterResponse: Codable {
    let deviceId: String
    let refreshToken: String
    let accessToken: String
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case refreshToken = "refresh_token"
        case accessToken = "access_token"
        case expiresAt = "expires_at"
    }

    init(deviceId: String, refreshToken: String, accessToken: String, expiresAt: Date) {
        self.deviceId = deviceId
        self.refreshToken = refreshToken
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        refreshToken = try container.decode(String.self, forKey: .refreshToken)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
            ?? Date(timeIntervalSinceNow: 3600)
    }
}

struct AccessTokenResponse: Codable {
    let accessToken: String
    let expiresAt: Date
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresAt = "expires_at"
    }
}

struct DeviceRegistrationRequest: Codable {
    let schema: String
    let pairingToken: String
    let deviceLabel: String
    let platform: String
    let appVersion: String

    enum CodingKeys: String, CodingKey {
        case schema
        case pairingToken = "pairing_token"
        case deviceLabel = "device_label"
        case platform
        case appVersion = "app_version"
    }
}

// MARK: - JSON encoder/decoder shared config

extension JSONEncoder {
    static var vitalsync: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var vitalsync: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

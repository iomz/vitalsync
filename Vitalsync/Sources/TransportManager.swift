import Foundation
import Security
import OSLog

private let log = Logger(subsystem: "io.sazanka.vitalsync", category: "Transport")

// MARK: - Transport errors

enum TransportError: LocalizedError {
    case accessTokenUnavailable
    case streamError(String)
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .accessTokenUnavailable:   return "Failed to obtain access token."
        case .streamError(let msg):     return "Stream error: \(msg)"
        case .httpError(let code, let msg): return "HTTP \(code): \(msg)"
        }
    }
}

// MARK: - Credential store (Keychain-backed)

final class CredentialStore {
    static let shared = CredentialStore()
    private let service = "io.sazanka.vitalsync"

    private init() {
        migrateItemsToBackgroundAccessibleStorage()
    }

    var deviceId: String? {
        get { keychainGet("device_id") }
        set { keychainSet("device_id", value: newValue) }
    }

    var accessToken: String? {
        get { keychainGet("access_token") }
        set { keychainSet("access_token", value: newValue) }
    }

    var refreshToken: String? {
        get { keychainGet("refresh_token") }
        set { keychainSet("refresh_token", value: newValue) }
    }

    var dailyStepSourceIdPrefix: String? {
        get { keychainGet("daily_step_count_source_id_prefix") }
        set { keychainSet("daily_step_count_source_id_prefix", value: newValue) }
    }

    var accessTokenExpiry: Date? {
        get { keychainGet("access_token_expiry").flatMap { TimeInterval($0).map { Date(timeIntervalSince1970: $0) } } }
        set { keychainSet("access_token_expiry", value: newValue.map { String($0.timeIntervalSince1970) }) }
    }

    func clear() {
        for key in ["device_id", "access_token", "refresh_token", "access_token_expiry", "daily_step_count_source_id_prefix"] {
            keychainSet(key, value: nil)
        }
    }

    private func migrateItemsToBackgroundAccessibleStorage() {
        for key in ["device_id", "access_token", "refresh_token", "access_token_expiry", "daily_step_count_source_id_prefix"] {
            guard let value = keychainGet(key) else { continue }
            let status = keychainSet(key, value: value)
            if status != errSecSuccess {
                log.error("Failed to migrate keychain item \(key): \(status)")
            }
        }
    }

    private func keychainGet(_ key: String) -> String? {
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private func keychainSet(_ key: String, value: String?) -> OSStatus {
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        if let value {
            let update: [CFString: Any] = [
                kSecValueData: value.data(using: .utf8)!,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                var add = q
                add[kSecValueData] = value.data(using: .utf8)!
                add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                return SecItemAdd(add as CFDictionary, nil)
            }
            return status
        } else {
            let status = SecItemDelete(q as CFDictionary)
            return status == errSecItemNotFound ? errSecSuccess : status
        }
    }
}

// MARK: - TransportManager

@MainActor
final class TransportManager: NSObject, ObservableObject {
    private static let defaultServerBaseURLString = "https://api.sazanka.io/vitalsync/v1"
    private let credentials: CredentialStore
    @Published var serverBaseURLString: String {
        didSet {
            UserDefaults.standard.set(serverBaseURLString, forKey: "server_base_url")
        }
    }

    @Published var isConnected = false
    @Published var serverReachable: Bool? = nil

    var hasRegisteredDevice: Bool {
        credentials.deviceId != nil
    }

    var connectionStatusText: String {
        guard hasRegisteredDevice else { return "Not registered" }
        if isConnected { return "Connected" }
        if serverReachable == true { return "Reachable" }
        if serverReachable == false { return "Unavailable" }
        return "Unknown"
    }

    init(credentials: CredentialStore = .shared) {
        self.credentials = credentials
        serverBaseURLString = UserDefaults.standard.string(forKey: "server_base_url")
            ?? Self.defaultServerBaseURLString
    }

    private var serverBase: URL {
        URL(string: serverBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: Self.defaultServerBaseURLString)!
    }

    static func validatedAPIBaseURLString(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty else {
            return nil
        }

        let normalizedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath.isEmpty {
            components.path = "/vitalsync/v1"
        } else if !normalizedPath.hasSuffix("vitalsync/v1") {
            components.path = "/" + normalizedPath + "/vitalsync/v1"
        }

        guard let normalized = components.string,
              URL(string: normalized) != nil else {
            return nil
        }
        return normalized
    }

    // MARK: - HTTPS upload

    func refreshConnectionStatus() async {
        guard hasRegisteredDevice else {
            serverReachable = nil
            isConnected = false
            return
        }

        do {
            var request = URLRequest(url: serverBase.appendingPathComponent("health"))
            request.httpMethod = "GET"
            request.timeoutInterval = 10
            let (_, response) = try await URLSession.shared.data(for: request)
            let reachable = (response as? HTTPURLResponse)?.statusCode == 200
            serverReachable = reachable
            guard reachable else {
                isConnected = false
                return
            }

            _ = try await validAccessToken()
            isConnected = true
        } catch {
            isConnected = false
            if serverReachable != true {
                serverReachable = false
            }
        }
    }

    func uploadViaHTTPS(_ batch: VitalsyncBatch) async throws {
        let token = try await validAccessToken()
        let url = serverBase.appendingPathComponent("batches")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(batch.batchId, forHTTPHeaderField: "Idempotency-Key")
        req.httpBody = try JSONEncoder.vitalsync.encode(batch)
        req.timeoutInterval = 180

        // Log only metadata
        log.info("HTTPS upload: batchId=\(batch.batchId) records=\(batch.records.count)")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw TransportError.streamError("No HTTP response") }

        if http.statusCode == 200 {
            serverReachable = true
            isConnected = true
            return
        }

        if let err = try? JSONDecoder.vitalsync.decode(ServerError.self, from: data) {
            throw TransportError.httpError(http.statusCode, err.message)
        }
        throw TransportError.httpError(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
    }

    func revokeDevice() async throws {
        guard let deviceId = credentials.deviceId else {
            credentials.clear()
            serverReachable = nil
            isConnected = false
            return
        }

        let token = try await validAccessToken()
        var req = URLRequest(url: serverBase.appendingPathComponent("devices/revoke"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder.vitalsync.encode(["device_id": deviceId])
        req.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw TransportError.streamError("No HTTP response") }
        guard http.statusCode == 200 else {
            if let err = try? JSONDecoder.vitalsync.decode(ServerError.self, from: data) {
                throw TransportError.httpError(http.statusCode, err.message)
            }
            throw TransportError.httpError(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }

        credentials.clear()
        serverReachable = nil
        isConnected = false
    }

    // MARK: - Token management

    func validAccessToken() async throws -> String {
        if let token = credentials.accessToken,
           let expiry = credentials.accessTokenExpiry,
           expiry.timeIntervalSinceNow > 60 {
            return token
        }
        return try await refreshAccessToken()
    }

    private func refreshAccessToken() async throws -> String {
        guard
            let refresh = credentials.refreshToken,
            let deviceId = credentials.deviceId
        else { throw TransportError.accessTokenUnavailable }

        var req = URLRequest(url: serverBase.appendingPathComponent("tokens/refresh"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder.vitalsync.encode(["refresh_token": refresh, "device_id": deviceId])

        let (data, response) = try await URLSession.shared.data(for: req)
        try validateHTTPResponse(response, data: data)
        let resp: AccessTokenResponse = try decodeServerJSON(data, context: "access token response")
        credentials.accessToken = resp.accessToken
        credentials.accessTokenExpiry = resp.expiresAt
        return resp.accessToken
    }

    private func decodeServerJSON<T: Decodable>(_ data: Data, context: String) throws -> T {
        do {
            return try JSONDecoder.vitalsync.decode(T.self, from: data)
        } catch {
            throw TransportError.streamError("Could not decode \(context): \(error.localizedDescription)")
        }
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw TransportError.streamError("No HTTP response")
        }
        guard http.statusCode == 200 else {
            if let err = try? JSONDecoder.vitalsync.decode(ServerError.self, from: data) {
                throw TransportError.httpError(http.statusCode, err.message)
            }
            throw TransportError.httpError(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
    }

    // MARK: - Device registration

    func register(deviceLabel: String, pairingToken: String) async throws {
        var req = URLRequest(url: serverBase.appendingPathComponent("devices/register"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = DeviceRegistrationRequest(
            schema: VitalsyncSchema.deviceRegistration,
            pairingToken: pairingToken,
            deviceLabel: deviceLabel,
            platform: "iOS",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        )
        req.httpBody = try JSONEncoder.vitalsync.encode(body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw TransportError.streamError("No HTTP response")
        }
        guard http.statusCode == 200 else {
            if let err = try? JSONDecoder.vitalsync.decode(ServerError.self, from: data) {
                throw TransportError.httpError(http.statusCode, err.message)
            }
            throw TransportError.httpError(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }

        let resp = try decodeRegisterResponse(data)
        credentials.deviceId = resp.deviceId
        credentials.accessToken = resp.accessToken
        credentials.accessTokenExpiry = resp.expiresAt
        credentials.refreshToken = resp.refreshToken
        serverReachable = true
        isConnected = true
        log.info("Device registered: \(resp.deviceId)")
    }

    private func decodeRegisterResponse(_ data: Data) throws -> RegisterResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TransportError.streamError("Registration response was not a JSON object")
        }

        func stringValue(_ snakeCase: String, _ camelCase: String) throws -> String {
            if let value = json[snakeCase] as? String, !value.isEmpty {
                return value
            }
            if let value = json[camelCase] as? String, !value.isEmpty {
                return value
            }
            throw TransportError.streamError("Registration response missing \(snakeCase)")
        }

        let expiresAt: Date
        if let rawExpiresAt = (json["expires_at"] as? String) ?? (json["expiresAt"] as? String),
           let parsedExpiresAt = ISO8601DateFormatter().date(from: rawExpiresAt) {
            expiresAt = parsedExpiresAt
        } else {
            expiresAt = Date(timeIntervalSinceNow: 3600)
        }

        return RegisterResponse(
            deviceId: try stringValue("device_id", "deviceId"),
            refreshToken: try stringValue("refresh_token", "refreshToken"),
            accessToken: try stringValue("access_token", "accessToken"),
            expiresAt: expiresAt
        )
    }
}

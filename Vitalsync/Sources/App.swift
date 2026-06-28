import AppIntents
import SwiftUI
import HealthKit
import UIKit

// MARK: - App Intents

struct SyncVitalsyncIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync Vitalsync"
    static var description = IntentDescription("Sync all enabled HealthKit data to sazanka.io.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let engine = AppDependencies.shared.syncEngine
        let groups = AppDependencies.shared.enabledTypeGroups
        await engine.syncNow(typeGroups: groups)
        let msg = engine.lastError ?? "Synced \(engine.lastBatchCount) batch(es)."
        return .result(dialog: IntentDialog(stringLiteral: msg))
    }
}

struct SyncSleepIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync Sleep"
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let group = HealthKitManager.typeGroups.first { $0.id == "sleep" }!
        await AppDependencies.shared.syncEngine.syncNow(typeGroups: [group])
        return .result(dialog: "Sleep data synced.")
    }
}

struct SyncActivityIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync Activity"
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let group = HealthKitManager.typeGroups.first { $0.id == "activity" }!
        await AppDependencies.shared.syncEngine.syncNow(typeGroups: [group])
        return .result(dialog: "Activity data synced.")
    }
}

struct SyncVitalsIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync Vitals"
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let group = HealthKitManager.typeGroups.first { $0.id == "vitals" }!
        await AppDependencies.shared.syncEngine.syncNow(typeGroups: [group])
        return .result(dialog: "Vitals synced.")
    }
}

struct ShowLastSyncStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Last Sync Status"
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let e = AppDependencies.shared.syncEngine
        let msg: String
        if let d = e.lastSyncDate {
            msg = "Last synced \(d.formatted(.relative(presentation: .named))). \(e.lastBatchCount) batch(es). \(e.lastError.map { "Error: \($0)" } ?? "No errors.")"
        } else {
            msg = "No sync has run yet."
        }
        return .result(dialog: IntentDialog(stringLiteral: msg))
    }
}

// MARK: - App dependencies (simple DI container)

@MainActor
final class AppDependencies: ObservableObject {
    static let shared = AppDependencies()

    let credentials = CredentialStore.shared
    let hkManager = HealthKitManager()
    let transport: TransportManager
    let syncEngine: SyncEngine
    @Published var enabledTypeGroups: [VitalsyncTypeGroup] = HealthKitManager.typeGroups
    @Published var pendingPairingToken: String?

    private init() {
        transport = TransportManager(credentials: credentials)
        syncEngine = SyncEngine(hkManager: hkManager, transport: transport, credentials: credentials)
    }

    func performBackgroundSync() async {
        await syncEngine.performBackgroundSync(typeGroups: enabledTypeGroups)
    }

    func configureBackgroundSync() async {
        await syncEngine.configureBackgroundSync(typeGroups: enabledTypeGroups)
    }

    func handleRegistrationURL(_ url: URL) {
        guard
            url.scheme == "vitalsync",
            url.host == "register",
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return }

        for item in components.queryItems ?? [] {
            switch item.name {
            case "base_url":
                if let value = item.value,
                   let apiBaseURL = TransportManager.validatedAPIBaseURLString(from: value) {
                    transport.serverBaseURLString = apiBaseURL
                }
            case "token":
                pendingPairingToken = item.value
            default:
                break
            }
        }
    }

}

// MARK: - Root app

@main
struct VitalsyncApp: App {
    @StateObject private var deps = AppDependencies.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(deps)
                .environmentObject(deps.syncEngine)
                .environmentObject(deps.transport)
                .onOpenURL { url in
                    deps.handleRegistrationURL(url)
                }
                .task {
                    await deps.transport.refreshConnectionStatus()
                    await deps.configureBackgroundSync()
                }
        }
        .backgroundTask(.appRefresh(SyncEngine.backgroundRefreshTaskIdentifier)) {
            await AppDependencies.shared.performBackgroundSync()
        }
    }
}

// MARK: - ContentView (tab bar)

struct ContentView: View {
    var body: some View {
        TabView {
            StatusView()
                .tabItem { Label("Status", systemImage: "dot.radiowaves.left.and.right") }
            DataTypesView()
                .tabItem { Label("Data types", systemImage: "heart.text.square") }
            SyncView()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
            AccountView()
                .tabItem { Label("Account", systemImage: "person.circle") }
        }
    }
}

// MARK: - Status screen

struct StatusView: View {
    @EnvironmentObject var deps: AppDependencies
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var transport: TransportManager

    var body: some View {
        NavigationStack {
            List {
                Section("HealthKit") {
                    ForEach(HealthKitManager.typeGroups) { group in
                        let status = deps.hkManager.readAuthorizationRequestStatus[group.id]
                        HStack {
                            Text(group.displayName)
                            Spacer()
                            Text(statusLabel(status))
                                .font(.caption)
                                .foregroundStyle(statusColor(status))
                        }
                    }
                }
                Section("Receiver") {
                    VitalsyncStatusRow(
                        label: "Connection",
                        value: transport.connectionStatusText,
                        ok: transport.isConnected ? true : (transport.serverReachable == false ? false : nil)
                    )
                    if let d = engine.lastSyncDate {
                        VitalsyncStatusRow(label: "Last sync", value: localTimestamp(d), ok: true)
                    } else {
                        VitalsyncStatusRow(label: "Last sync", value: "Never", ok: nil)
                    }
                    VitalsyncStatusRow(label: "Last batch count", value: "\(engine.lastSuccessfulBatchCount)", ok: nil)
                    if let err = engine.lastError {
                        VitalsyncStatusRow(label: "Last error", value: err, ok: false)
                    }
                }
            }
            .navigationTitle("Status")
            .task {
                await deps.hkManager.refreshReadAuthorizationStatus(for: HealthKitManager.typeGroups)
                await transport.refreshConnectionStatus()
            }
        }
    }

    private func statusLabel(_ s: HKAuthorizationRequestStatus?) -> String {
        switch s {
        case .unnecessary:   return "Ready"
        case .shouldRequest: return "Needs access"
        case .unknown:       return "Unknown"
        default:             return "Unknown"
        }
    }

    private func statusColor(_ s: HKAuthorizationRequestStatus?) -> Color {
        switch s {
        case .unnecessary:   return .green
        case .shouldRequest: return .orange
        case .unknown:       return .secondary
        default:             return .secondary
        }
    }

    private func localTimestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}

struct VitalsyncStatusRow: View {
    let label: String
    let value: String
    let ok: Bool?
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            if let ok {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? .green : .red)
            }
            Text(value).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Data Types screen

struct DataTypesView: View {
    @EnvironmentObject var deps: AppDependencies
    @State private var isRequestingPermissions = false
    @State private var permissionRequestStatus: HKAuthorizationRequestStatus?
    @State private var requestedPermissionGroupIDs = Set<String>()
    @State private var permissionDialog: HealthPermissionDialog?

    private static let requestedPermissionGroupIDsKey = "requested_permission_group_ids"

    var body: some View {
        NavigationStack {
            List {
                ForEach(deps.enabledTypeGroups.indices, id: \.self) { i in
                    Toggle(
                        deps.enabledTypeGroups[i].displayName,
                        isOn: Binding(
                            get: { deps.enabledTypeGroups[i].enabled },
                            set: { isEnabled in
                                deps.enabledTypeGroups[i].enabled = isEnabled
                                Task { await deps.configureBackgroundSync() }
                                Task { await refreshPermissionRequestStatus() }
                            }
                        )
                    )
                }

                if shouldShowHealthAccessSection {
                    Section("Health access") {
                        if shouldShowPermissionRequest {
                            Button(isRequestingPermissions ? "Requesting…" : "Request permissions") {
                                Task { await requestHealthAccess() }
                            }
                            .disabled(isRequestingPermissions)
                        }

                        if shouldShowManageHealthAccess {
                            Button("Manage Health Access") {
                                showManageHealthAccessHelp()
                            }
                        }
                    }
                }

            }
            .navigationTitle("Data types")
            .task {
                requestedPermissionGroupIDs = loadRequestedPermissionGroupIDs()
                await refreshPermissionRequestStatus()
                await deps.hkManager.refreshReadAuthorizationStatus(for: deps.enabledTypeGroups)
            }
            .alert(item: $permissionDialog) { dialog in
                switch dialog.action {
                case .settings:
                    return Alert(
                        title: Text(dialog.title),
                        message: Text(dialog.message),
                        primaryButton: .default(Text("Open Settings")) {
                            openAppSettings()
                        },
                        secondaryButton: .cancel()
                    )
                case .info:
                    return Alert(
                        title: Text(dialog.title),
                        message: Text(dialog.message),
                        dismissButton: .default(Text("OK"))
                    )
                }
            }
        }
    }

    private var shouldShowHealthAccessSection: Bool {
        shouldShowPermissionRequest || shouldShowManageHealthAccess
    }

    private var shouldShowPermissionRequest: Bool {
        permissionRequestStatus == .shouldRequest
    }

    private var shouldShowManageHealthAccess: Bool {
        !requestedPermissionGroupIDs.isEmpty
    }

    private var enabledPermissionGroupIDs: Set<String> {
        Set(deps.enabledTypeGroups.filter(\.enabled).map(\.id))
    }

    private func loadRequestedPermissionGroupIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.requestedPermissionGroupIDsKey) ?? [])
    }

    private func markEnabledGroupsPermissionRequested() {
        requestedPermissionGroupIDs.formUnion(enabledPermissionGroupIDs)
        UserDefaults.standard.set(
            Array(requestedPermissionGroupIDs).sorted(),
            forKey: Self.requestedPermissionGroupIDsKey
        )
    }

    private func refreshPermissionRequestStatus() async {
        guard HealthKitManager.isHealthDataAvailable,
              deps.enabledTypeGroups.contains(where: \.enabled) else {
            permissionRequestStatus = nil
            return
        }

        permissionRequestStatus = try? await deps.hkManager.authorizationRequestStatus(
            groups: deps.enabledTypeGroups
        )
        await deps.hkManager.refreshReadAuthorizationStatus(for: deps.enabledTypeGroups)
        if permissionRequestStatus == .unnecessary {
            markEnabledGroupsPermissionRequested()
        }
    }


    private func requestHealthAccess() async {
        isRequestingPermissions = true
        defer { isRequestingPermissions = false }

        do {
            try await deps.hkManager.requestAuthorization(groups: deps.enabledTypeGroups)
            markEnabledGroupsPermissionRequested()
            let requestStatus = try await deps.hkManager.authorizationRequestStatus(
                groups: deps.enabledTypeGroups
            )
            permissionRequestStatus = requestStatus
            if requestStatus == .unknown {
                permissionDialog = HealthPermissionDialog(
                    title: "Health permission status unavailable",
                    message: "Open Settings to review Vitalsync Health access.",
                    action: .settings
                )
            }
        } catch {
            permissionDialog = HealthPermissionDialog(
                title: "Health permission failed",
                message: error.localizedDescription,
                action: .settings
            )
        }
    }

    private func showManageHealthAccessHelp() {
        permissionDialog = HealthPermissionDialog(
            title: "Manage Health access",
            message: "Open the Health app, then go to Sharing > Apps > Vitalsync to review read access for each data type.",
            action: .info
        )
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

struct HealthPermissionDialog: Identifiable {
    enum Action {
        case settings
        case info
    }

    let id = UUID()
    let title: String
    let message: String
    let action: Action
}

// MARK: - Sync screen

struct SyncView: View {
    @EnvironmentObject var deps: AppDependencies
    @EnvironmentObject var engine: SyncEngine
    @State private var showingDebugBundle = false
    @State private var showResetSyncHistory = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button(engine.isSyncing ? "Syncing…" : "Sync now") {
                        Task { await engine.syncNow(typeGroups: deps.enabledTypeGroups) }
                    }
                    .disabled(engine.isSyncing)
                    if let syncStatus = engine.syncStatus {
                        Text(syncStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Last attempt") {
                    if let lastAttemptDate = engine.lastAttemptDate {
                        LabeledContent("Time", value: localTimestamp(lastAttemptDate))
                    } else {
                        LabeledContent("Time", value: "Never")
                    }
                    LabeledContent("Records", value: "\(engine.lastRecordCount)")
                    LabeledContent("Deleted", value: "\(engine.lastDeletedCount)")
                    LabeledContent("Batches", value: "\(engine.lastBatchCount)")
                }
                Section("Background sync") {
                    Toggle("Enable background sync", isOn: $engine.backgroundSyncEnabled)
                }
                Section("Pending uploads") {
                    Text("\(engine.pendingCount) batch(es) pending")
                        .foregroundStyle(engine.pendingCount > 0 ? .orange : .secondary)
                    Button("Retry pending") {
                        Task { await engine.retryPending() }
                    }.disabled(engine.pendingCount == 0)
                }
                Section("Debug") {
                    Button("Export debug bundle") { showingDebugBundle = true }
                    Button("Reset sync history", role: .destructive) { showResetSyncHistory = true }
                        .disabled(engine.isSyncing)
                }
            }
            .navigationTitle("Sync")
            .confirmationDialog(
                "Reset sync history?",
                isPresented: $showResetSyncHistory,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    Task {
                        await engine.resetSyncHistory(
                            typeGroups: deps.enabledTypeGroups.filter(\.enabled)
                        )
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The next sync will re-query all enabled Health data from HealthKit.")
            }
        }
        .sheet(isPresented: $showingDebugBundle) {
            DebugBundleView()
        }
        .onChange(of: engine.backgroundSyncEnabled) { _, _ in
            Task { await deps.configureBackgroundSync() }
        }
    }

    private func localTimestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}

// MARK: - Account screen

struct AccountView: View {
    @EnvironmentObject var deps: AppDependencies
    @EnvironmentObject var transport: TransportManager
    @State private var deviceLabel = ""
    @State private var serverBaseURLDraft = ""
    @State private var defaultDeviceLabel = Self.currentDefaultDeviceLabel
    @State private var credentialStatus = CredentialStatus()
    @State private var pairingToken = ""
    @State private var registrationError: String?
    @State private var isRegistering = false
    @State private var showRevoke = false
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationStack {
            Form {
                Section("Receiver") {
                    TextField("API base URL", text: $serverBaseURLDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .focused($focusedField, equals: .serverBaseURL)
                        .onSubmit(commitServerBaseURL)
                }
                Section("Device") {
                    if let id = credentialStatus.deviceId {
                        LabeledContent("Device ID", value: String(id.prefix(16)) + "…")
                    } else {
                        TextField("Device label", text: $deviceLabel, prompt: Text(defaultDeviceLabel))
                            .autocorrectionDisabled()
                        PairingTokenField(token: $pairingToken)
                        Button(isRegistering ? "Registering…" : "Register device") {
                            Task { await registerDevice() }
                        }
                        .disabled(trimmedPairingToken.isEmpty || isRegistering)
                        if let registrationError {
                            Text(registrationError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                Section("Token") {
                    LabeledContent("Access token", value: credentialStatus.hasAccessToken ? "Present" : "None")
                    LabeledContent("Refresh token", value: credentialStatus.hasRefreshToken ? "Present" : "None")
                    Button("Revoke device", role: .destructive) { showRevoke = true }
                        .disabled(credentialStatus.deviceId == nil)
                    if let registrationError {
                        Text(registrationError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Account")
            .onChange(of: focusedField) { _, newValue in
                if newValue != .serverBaseURL {
                    commitServerBaseURL()
                }
            }
            .confirmationDialog("Revoke this device?", isPresented: $showRevoke, titleVisibility: .visible) {
                Button("Revoke", role: .destructive) {
                    Task { await revokeDevice() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove all credentials. You'll need to re-register.")
            }
            .task {
                serverBaseURLDraft = transport.serverBaseURLString
                defaultDeviceLabel = Self.currentDefaultDeviceLabel
                applyPendingPairingToken()
                refreshCredentialStatus()
            }
            .onChange(of: transport.serverBaseURLString) { _, newValue in
                guard focusedField != .serverBaseURL else { return }
                serverBaseURLDraft = newValue
            }
            .onChange(of: deps.pendingPairingToken) { _, _ in
                applyPendingPairingToken()
            }
        }
    }

    private func revokeDevice() async {
        registrationError = nil
        do {
            try await transport.revokeDevice()
            refreshCredentialStatus()
        } catch {
            registrationError = error.localizedDescription
        }
    }

    private static var currentDefaultDeviceLabel: String {
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? UIDevice.current.localizedModel : name
    }

    private var registrationDeviceLabel: String {
        let label = deviceLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? defaultDeviceLabel : label
    }

    private var trimmedPairingToken: String {
        pairingToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func registerDevice() async {
        commitServerBaseURL()
        isRegistering = true
        registrationError = nil
        defer { isRegistering = false }

        do {
            try await deps.transport.register(
                deviceLabel: registrationDeviceLabel,
                pairingToken: trimmedPairingToken
            )
            pairingToken = ""
            deps.pendingPairingToken = nil
            refreshCredentialStatus()
        } catch {
            registrationError = error.localizedDescription
        }
    }

    private func applyPendingPairingToken() {
        guard let token = deps.pendingPairingToken else { return }
        pairingToken = token
    }

    private func commitServerBaseURL() {
        let trimmed = serverBaseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != transport.serverBaseURLString else { return }
        guard let apiBaseURL = TransportManager.validatedAPIBaseURLString(from: trimmed) else {
            registrationError = "Invalid receiver API base URL."
            serverBaseURLDraft = transport.serverBaseURLString
            return
        }
        registrationError = nil
        serverBaseURLDraft = apiBaseURL
        transport.serverBaseURLString = apiBaseURL
    }

    private func refreshCredentialStatus() {
        credentialStatus = CredentialStatus(credentials: deps.credentials)
    }

    private enum Field: Hashable {
        case serverBaseURL
    }

    private struct CredentialStatus {
        var deviceId: String?
        var hasAccessToken = false
        var hasRefreshToken = false

        init() {}

        init(credentials: CredentialStore) {
            deviceId = credentials.deviceId
            hasAccessToken = credentials.accessToken != nil
            hasRefreshToken = credentials.refreshToken != nil
        }
    }
}

struct PairingTokenField: View {
    @Binding var token: String
    @State private var isRevealed = false

    var body: some View {
        HStack {
            ZStack(alignment: .leading) {
                if token.isEmpty {
                    Text("Pairing token")
                        .foregroundStyle(.secondary)
                }
                TextField("", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(isRevealed ? .primary : .clear)
                    .submitLabel(.done)
                if !isRevealed && !token.isEmpty {
                    Text(String(repeating: "•", count: token.count))
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
            }

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isRevealed ? "Hide pairing token" : "Reveal pairing token")
        }
    }
}

// MARK: - Debug bundle view (metadata only, no raw values)

struct DebugBundleView: View {
    @EnvironmentObject var deps: AppDependencies
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) var dismiss

    var debugMetadata: String {
        """
        Vitalsync — debug bundle
        Generated: \(Date().formatted())
        Device ID: \(deps.credentials.deviceId ?? "not registered")
        Last successful sync: \(engine.lastSyncDate?.formatted(date: .abbreviated, time: .standard) ?? "never")
        Last attempt: \(engine.lastAttemptDate?.formatted(date: .abbreviated, time: .standard) ?? "never")
        Last records: \(engine.lastRecordCount)
        Last deleted: \(engine.lastDeletedCount)
        Last attempt batch count: \(engine.lastBatchCount)
        Last successful batch count: \(engine.lastSuccessfulBatchCount)
        Pending batches: \(engine.pendingCount)
        Sync status: \(engine.syncStatus ?? "idle")
        Last error: \(engine.lastError ?? "none")

        [Raw health values are excluded from debug bundles]
        """
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(debugMetadata)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Debug bundle")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: debugMetadata, subject: Text("Vitalsync Debug"))
                }
            }
        }
    }
}

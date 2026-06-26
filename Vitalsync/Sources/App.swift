import AppIntents
import SwiftUI
import HealthKit

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

    private init() {
        transport = TransportManager(credentials: credentials)
        syncEngine = SyncEngine(hkManager: hkManager, transport: transport, credentials: credentials)
    }

    func performBackgroundSync() async {
        await syncEngine.performBackgroundSync(typeGroups: enabledTypeGroups)
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
                .task {
                    deps.syncEngine.scheduleBackgroundSync()
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
                .tabItem { Label("Data types", systemImage: "list.bullet.health") }
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
                        let status = deps.hkManager.authorizationStatus[group.id]
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
                    VitalsyncStatusRow(label: "Connection", value: transport.isConnected ? "Connected" : "Disconnected",
                                 ok: transport.isConnected)
                    if let d = engine.lastSyncDate {
                        VitalsyncStatusRow(label: "Last sync", value: d.formatted(.relative(presentation: .named)), ok: true)
                    } else {
                        VitalsyncStatusRow(label: "Last sync", value: "Never", ok: nil)
                    }
                    VitalsyncStatusRow(label: "Last batch count", value: "\(engine.lastBatchCount)", ok: nil)
                    if let err = engine.lastError {
                        VitalsyncStatusRow(label: "Last error", value: err, ok: false)
                    }
                }
            }
            .navigationTitle("Status")
        }
    }

    private func statusLabel(_ s: HKAuthorizationStatus?) -> String {
        switch s {
        case .sharingAuthorized: return "Authorized"
        case .sharingDenied:     return "Denied"
        default:                 return "Not determined"
        }
    }

    private func statusColor(_ s: HKAuthorizationStatus?) -> Color {
        switch s {
        case .sharingAuthorized: return .green
        case .sharingDenied:     return .red
        default:                 return .secondary
        }
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

    var body: some View {
        NavigationStack {
            List {
                ForEach(deps.enabledTypeGroups.indices, id: \.self) { i in
                    Toggle(deps.enabledTypeGroups[i].displayName,
                           isOn: $deps.enabledTypeGroups[i].enabled)
                }
            }
            .navigationTitle("Data types")
            .toolbar {
                Button("Request permissions") {
                    Task {
                        try? await deps.hkManager.requestAuthorization(
                            groups: deps.enabledTypeGroups
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Sync screen

struct SyncView: View {
    @EnvironmentObject var deps: AppDependencies
    @EnvironmentObject var engine: SyncEngine
    @State private var showingDebugBundle = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button(engine.isSyncing ? "Syncing…" : "Sync now") {
                        Task { await engine.syncNow(typeGroups: deps.enabledTypeGroups) }
                    }
                    .disabled(engine.isSyncing)
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
                }
            }
            .navigationTitle("Sync")
        }
        .sheet(isPresented: $showingDebugBundle) {
            DebugBundleView()
        }
    }
}

// MARK: - Account screen

struct AccountView: View {
    @EnvironmentObject var deps: AppDependencies
    @EnvironmentObject var transport: TransportManager
    @State private var deviceLabel = ""
    @State private var showRevoke = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Receiver") {
                    TextField("API base URL", text: $transport.serverBaseURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Section("Device") {
                    if let id = deps.credentials.deviceId {
                        LabeledContent("Device ID", value: String(id.prefix(16)) + "…")
                    } else {
                        TextField("Device label", text: $deviceLabel)
                        Button("Register device") {
                            Task {
                                try? await deps.transport.register(deviceLabel: deviceLabel)
                            }
                        }
                        .disabled(deviceLabel.isEmpty)
                    }
                }
                Section("Token") {
                    LabeledContent("Access token", value: deps.credentials.accessToken != nil ? "Present" : "None")
                    LabeledContent("Refresh token", value: deps.credentials.refreshToken != nil ? "Present" : "None")
                    Button("Revoke device", role: .destructive) { showRevoke = true }
                        .disabled(deps.credentials.deviceId == nil)
                }
            }
            .navigationTitle("Account")
            .confirmationDialog("Revoke this device?", isPresented: $showRevoke, titleVisibility: .visible) {
                Button("Revoke", role: .destructive) { deps.credentials.clear() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove all credentials. You'll need to re-register.")
            }
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
        Last sync: \(engine.lastSyncDate?.formatted() ?? "never")
        Last batch count: \(engine.lastBatchCount)
        Pending batches: \(engine.pendingCount)
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

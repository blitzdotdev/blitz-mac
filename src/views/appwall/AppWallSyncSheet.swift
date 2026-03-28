import SwiftUI

struct AppWallSyncSheet: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appWallSyncConsented") private var syncConsented: Bool = false

    @State private var sheetState: SheetState = .validating

    enum SheetState {
        case validating
        case noCredentials
        case ready
        case syncing
        case done(count: Int, warning: String?)
        case error(String)
    }

    var body: some View {
        Group {
            switch sheetState {
            case .validating:
                validatingView
            case .noCredentials:
                noCredentialsView
            case .ready:
                readyView
            case .syncing:
                syncingView
            case .done(let count, let warning):
                doneView(count: count, warning: warning)
            case .error(let message):
                errorView(message: message)
            }
        }
        .frame(width: 480)
        .task { await validateAndPrepare() }
    }

    // MARK: - State Views

    private var validatingView: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Checking credentials…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(48)
    }

    private var noCredentialsView: some View {
        VStack(spacing: 20) {
            Image(systemName: "key.slash")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            VStack(spacing: 6) {
                Text("Credentials Required")
                    .font(.title2.weight(.bold))
                Text("Valid App Store Connect API credentials are needed to sync your apps.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Set Up Credentials") {
                dismiss()
                appState.activeTab = .app
                appState.activeAppSubTab = .overview
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var readyView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Hero
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.blue.opacity(0.12))
                            .frame(width: 52, height: 52)
                        Image(systemName: "globe")
                            .font(.title2)
                            .foregroundStyle(.blue)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Join the Blitz App Wall")
                            .font(.title2.weight(.bold))
                        Text("Showcase your apps to thousands of iOS developers")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    featureRow("chart.bar.fill", .blue, "See how your review times compare with the community")
                    featureRow("megaphone.fill", .purple, "Get discovered by potential users and collaborators")
                    featureRow("shield.checkered", .green, "Help surface unfair rejections through transparency data")
                }
            }
            .padding(28)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                Text("Syncing shares your app's public store listing info (name, icon, bundle ID) and submission history. You can opt out at any time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Not Now") { dismiss() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Sync My Apps") { startSync() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(28)
        }
    }

    private var syncingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Syncing your apps…")
                .font(.callout.weight(.medium))
            Text("This may take a moment")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(48)
    }

    private func doneView(count: Int, warning: String?) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(warning == nil ? .green : .orange)
            VStack(spacing: 6) {
                Text(warning == nil ? "Sync Complete!" : "Sync Complete with Issues")
                    .font(.title2.weight(.bold))
                if count > 0 {
                    Text("\(count) app\(count == 1 ? "" : "s") added to the Blitz App Wall.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No live apps found on your account.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let warning, !warning.isEmpty {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            VStack(spacing: 6) {
                Text("Sync Failed")
                    .font(.title2.weight(.bold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button("Try Again") { startSync() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    @ViewBuilder
    private func featureRow(_ icon: String, _ color: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(color)
                .frame(width: 20)
            Text(text)
                .font(.callout)
        }
    }

    // MARK: - Actions

    private func validateAndPrepare() async {
        guard let credentials = ASCCredentials.load() else {
            sheetState = .noCredentials
            return
        }
        do {
            let valid = try await AppWallService.shared.validateCredentials(credentials)
            sheetState = valid ? .ready : .noCredentials
        } catch {
            sheetState = .noCredentials
        }
    }

    private func startSync() {
        guard let credentials = ASCCredentials.load() else {
            sheetState = .noCredentials
            return
        }
        sheetState = .syncing

        Task {
            do {
                let ascService = AppStoreConnectService(credentials: credentials)
                let irisSession = await MainActor.run { IrisSession.load() }
                // Only sync apps that exist as local Blitz projects — not the entire developer account
                let localBundleIds = Set(appState.projectManager.projects.compactMap {
                    $0.metadata.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty })

                let allLiveApps = try await ascService.fetchAllApps(appStoreStateFilter: "READY_FOR_SALE")
                let ascApps = allLiveApps.filter { localBundleIds.contains($0.bundleId) }

                // Fetch all sync data for each app in parallel.
                var syncDataItems: [AppWallSyncData] = []
                var versionFetchFailures: [String] = []
                await withTaskGroup(of: (AppWallSyncData?, String?).self) { group in
                    for app in ascApps {
                        group.addTask {
                            do {
                                let versions = try await ascService.fetchAppStoreVersions(appId: app.id)
                                guard !versions.isEmpty else {
                                    return (nil, "\(app.bundleId) (No App Store versions were returned)")
                                }
                                let syncData = await AppWallSyncDataBuilder.build(
                                    app: app,
                                    versions: versions,
                                    service: ascService,
                                    irisSession: irisSession
                                )
                                return (syncData, nil)
                            } catch {
                                return (nil, "\(app.bundleId) (\(error.localizedDescription))")
                            }
                        }
                    }
                    for await (syncData, failure) in group {
                        if let syncData {
                            syncDataItems.append(syncData)
                        } else {
                            if let failure {
                                Log("[AppWall] sync data fetch failed: \(failure)")
                                versionFetchFailures.append(failure)
                            }
                        }
                    }
                }

                let result = try await AppWallService.shared.syncApps(
                    credentials: credentials,
                    syncData: syncDataItems
                )

                if !result.successfulBundleIds.isEmpty {
                    // Persist only confirmed successes locally — used for the
                    // "unsynced" banner check without re-querying the wall.
                    AppWallSyncedBundleIds.add(result.successfulBundleIds)
                }

                let pushFailures = result.failures.map { "\($0.bundleId) (\($0.reason))" }
                let allFailures = versionFetchFailures + pushFailures

                if allFailures.isEmpty {
                    syncConsented = true
                    sheetState = .done(count: result.successCount, warning: nil)
                } else if result.successCount > 0 {
                    syncConsented = true
                    sheetState = .done(
                        count: result.successCount,
                        warning: summarizeFailures(allFailures)
                    )
                } else {
                    sheetState = .error(summarizeFailures(allFailures))
                }
            } catch {
                sheetState = .error(error.localizedDescription)
            }
        }
    }

    private func summarizeFailures(_ failures: [String]) -> String {
        let uniqueFailures = Array(NSOrderedSet(array: failures)) as? [String] ?? failures
        let preview = uniqueFailures.prefix(3).joined(separator: ", ")
        let remainingCount = uniqueFailures.count - min(uniqueFailures.count, 3)

        if preview.isEmpty {
            return "One or more apps failed to sync."
        }
        if remainingCount > 0 {
            return "\(uniqueFailures.count) apps failed to sync: \(preview), and \(remainingCount) more."
        }
        return "\(uniqueFailures.count) app\(uniqueFailures.count == 1 ? "" : "s") failed to sync: \(preview)."
    }
}

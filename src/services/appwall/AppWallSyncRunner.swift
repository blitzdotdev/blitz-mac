import Foundation

struct AppWallSyncExecutionResult {
    let successCount: Int
    let successfulBundleIds: Set<String>
    let failures: [String]

    var warning: String? {
        AppWallSyncRunner.summarizeFailures(failures)
    }
}

enum AppWallSyncRunner {
    @MainActor
    static func syncLocalLiveApps(
        projects: [Project],
        credentials: ASCCredentials
    ) async throws -> AppWallSyncExecutionResult {
        let ascService = AppStoreConnectService(credentials: credentials)
        let irisSession = IrisSession.load()
        let localBundleIds = Set(projects.compactMap {
            $0.metadata.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })

        guard !localBundleIds.isEmpty else {
            Log("[AppWall] sync skipped: no local bundle IDs found")
            return AppWallSyncExecutionResult(
                successCount: 0,
                successfulBundleIds: Set<String>(),
                failures: []
            )
        }

        let allLiveApps = try await ascService.fetchAllApps(appStoreStateFilter: "READY_FOR_SALE")
        let ascApps = allLiveApps.filter { localBundleIds.contains($0.bundleId) }
        Log("[AppWall] hydrating \(ascApps.count) live local app(s) for sync")

        guard !ascApps.isEmpty else {
            return AppWallSyncExecutionResult(
                successCount: 0,
                successfulBundleIds: Set<String>(),
                failures: []
            )
        }

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
                } else if let failure {
                    Log("[AppWall] sync data fetch failed: \(failure)")
                    versionFetchFailures.append(failure)
                }
            }
        }

        let result = try await AppWallService.shared.syncApps(
            credentials: credentials,
            syncData: syncDataItems
        )

        if !result.successfulBundleIds.isEmpty {
            AppWallSyncedBundleIds.add(result.successfulBundleIds)
        }

        let pushFailures = result.failures.map { "\($0.bundleId) (\($0.reason))" }
        return AppWallSyncExecutionResult(
            successCount: result.successCount,
            successfulBundleIds: result.successfulBundleIds,
            failures: versionFetchFailures + pushFailures
        )
    }

    static func summarizeFailures(_ failures: [String]) -> String? {
        guard !failures.isEmpty else { return nil }

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

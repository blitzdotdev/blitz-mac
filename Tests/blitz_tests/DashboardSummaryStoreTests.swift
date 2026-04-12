import Foundation
import Testing
@testable import Blitz

@MainActor
@Test func dashboardSummaryStoreRestoresMatchingPersistentCache() throws {
    let cacheURL = makeDashboardCacheURL()
    defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
    let summary = ASCDashboardSummary(liveCount: 1, pendingCount: 0, rejectedCount: 0)
    let status = ASCDashboardProjectStatus(isLiveOnStore: true, isPendingReview: false, isRejected: false)
    let row = DashboardAppRow(
        id: "com.example.cached",
        bundleId: "com.example.cached",
        name: "Cached App",
        source: .asc,
        ascAppId: "123",
        linkedProjectId: "project-1",
        status: status
    )

    let writer = DashboardSummaryStore(cacheURL: cacheURL, accountKeyOverride: "issuer:key")
    writer.store(
        summary: summary,
        projectStatuses: ["com.example.cached": status],
        ascApps: [
            ASCApp(
                id: "123",
                attributes: ASCApp.Attributes(
                    bundleId: "com.example.cached",
                    name: "Cached App",
                    primaryLocale: nil,
                    vendorNumber: nil,
                    contentRightsDeclaration: nil
                )
            )
        ],
        appRows: [row],
        for: "seed",
        accountKey: "issuer:key"
    )

    let restored = DashboardSummaryStore(cacheURL: cacheURL, accountKeyOverride: "issuer:key")
    #expect(restored.hasLoadedSummary)
    #expect(restored.summary == summary)
    #expect(restored.projectStatuses == ["com.example.cached": status])
    #expect(restored.appRows == [row])
}

@MainActor
@Test func dashboardSummaryStoreKeepsCachedAppsWhenRefreshFails() {
    let cacheURL = makeDashboardCacheURL()
    defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
    let row = DashboardAppRow(
        id: "com.example.cached",
        bundleId: "com.example.cached",
        name: "Cached App",
        source: .asc,
        ascAppId: "123",
        linkedProjectId: nil,
        status: .empty
    )

    let store = DashboardSummaryStore(cacheURL: cacheURL, accountKeyOverride: "issuer:key")
    store.store(
        summary: .empty,
        projectStatuses: ["com.example.cached": .empty],
        ascApps: [
            ASCApp(
                id: "123",
                attributes: ASCApp.Attributes(
                    bundleId: "com.example.cached",
                    name: "Cached App",
                    primaryLocale: nil,
                    vendorNumber: nil,
                    contentRightsDeclaration: nil
                )
            )
        ],
        appRows: [row],
        for: "seed",
        accountKey: "issuer:key"
    )

    store.beginLoading(for: "refresh", accountKey: "issuer:key")
    store.markUnavailable(for: "refresh", accountKey: "issuer:key")

    #expect(store.hasLoadedSummary)
    #expect(!store.isLoadingSummary)
    #expect(store.appRows == [row])
}

@MainActor
@Test func dashboardSummaryStoreClearsStaleAppsForDifferentAccount() {
    let cacheURL = makeDashboardCacheURL()
    defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
    let row = DashboardAppRow(
        id: "com.example.cached",
        bundleId: "com.example.cached",
        name: "Cached App",
        source: .asc,
        ascAppId: "123",
        linkedProjectId: nil,
        status: .empty
    )

    let store = DashboardSummaryStore(cacheURL: cacheURL, accountKeyOverride: "issuer:key")
    store.store(
        summary: .empty,
        projectStatuses: ["com.example.cached": .empty],
        ascApps: [
            ASCApp(
                id: "123",
                attributes: ASCApp.Attributes(
                    bundleId: "com.example.cached",
                    name: "Cached App",
                    primaryLocale: nil,
                    vendorNumber: nil,
                    contentRightsDeclaration: nil
                )
            )
        ],
        appRows: [row],
        for: "seed",
        accountKey: "issuer:key"
    )

    store.beginLoading(for: "other-account", accountKey: "other-issuer:key")

    #expect(!store.hasLoadedSummary)
    #expect(store.isLoadingSummary)
    #expect(store.appRows.isEmpty)
    #expect(store.projectStatuses.isEmpty)
}

@MainActor
@Test func dashboardSummaryStoreRelinksCachedAppsAgainstCurrentProjects() {
    let cacheURL = makeDashboardCacheURL()
    defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

    let store = DashboardSummaryStore(cacheURL: cacheURL, accountKeyOverride: "issuer:key")
    store.store(
        summary: .empty,
        projectStatuses: ["com.example.cached": .empty],
        ascApps: [
            ASCApp(
                id: "123",
                attributes: ASCApp.Attributes(
                    bundleId: "com.example.cached",
                    name: "Cached App",
                    primaryLocale: nil,
                    vendorNumber: nil,
                    contentRightsDeclaration: nil
                )
            )
        ],
        appRows: [
            DashboardAppRow(
                id: "com.example.cached",
                bundleId: "com.example.cached",
                name: "Cached App",
                source: .asc,
                ascAppId: "123",
                linkedProjectId: nil,
                status: .empty
            )
        ],
        for: "seed",
        accountKey: "issuer:key"
    )

    let rows = store.rows(linking: [
        Project(
            id: "project-1",
            metadata: BlitzProjectMetadata(
                name: "Local Project",
                type: .swift,
                bundleIdentifier: "com.example.cached"
            ),
            path: "/tmp/project-1"
        )
    ])

    #expect(rows.count == 1)
    #expect(rows.first?.linkedProjectId == "project-1")
}

private func makeDashboardCacheURL() -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    return directory.appendingPathComponent("dashboard-my-apps-cache.json")
}

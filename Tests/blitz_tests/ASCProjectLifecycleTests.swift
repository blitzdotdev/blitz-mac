import Foundation
import Testing
@testable import Blitz

@MainActor
@Test func projectSwitchSkipsSnapshotWhenBundleIdDoesNotMatch() {
    let manager = ASCManager()
    manager.loadedProjectId = "sunnyville"
    manager.app = makeProjectSwitchApp(bundleId: "com.example.sunnyville")
    manager.appStoreVersions = [
        makeProjectSwitchVersion(id: "sunny-101", versionString: "1.0.1")
    ]
    manager.loadedTabs = [.app]
    manager.tabLoadedAt = [.app: Date()]

    let mismatchedSnapshot = ASCManager.ProjectSnapshot(manager: manager, projectId: "other-project")
    manager.projectSnapshots["other-project"] = mismatchedSnapshot

    manager.prepareForProjectSwitch(to: "other-project", bundleId: "com.example.other")

    #expect(manager.loadedProjectId == "other-project")
    #expect(manager.app == nil)
    #expect(manager.appStoreVersions.isEmpty)
    #expect(manager.loadedTabs.isEmpty)
}

@MainActor
@Test func syncOverviewSubmissionReadinessWaitsForOverviewHydrationTask() async {
    let manager = ASCManager()
    let credentials = ASCCredentials(issuerId: "issuer", keyId: "key", privateKey: "private")
    manager.credentials = credentials
    manager.service = AppStoreConnectService(credentials: credentials)
    manager.loadedTabs = [.app]
    manager.tabLoadedAt = [.app: Date()]
    manager.monetizationStatus = nil

    manager.startBackgroundHydration(for: .app) {
        try? await Task.sleep(for: .milliseconds(50))
        manager.monetizationStatus = "Configured"
    }

    await manager.syncOverviewSubmissionReadiness()

    #expect(manager.monetizationStatus == "Configured")
}

private func makeProjectSwitchApp(bundleId: String) -> ASCApp {
    ASCApp(
        id: "app-id",
        attributes: ASCApp.Attributes(
            bundleId: bundleId,
            name: "Example",
            primaryLocale: "en-US",
            vendorNumber: nil,
            contentRightsDeclaration: nil
        )
    )
}

private func makeProjectSwitchVersion(id: String, versionString: String) -> ASCAppStoreVersion {
    ASCAppStoreVersion(
        id: id,
        attributes: ASCAppStoreVersion.Attributes(
            versionString: versionString,
            appStoreState: "READY_FOR_SALE",
            releaseType: nil,
            createdDate: "2026-03-28T00:00:00Z",
            copyright: nil
        )
    )
}

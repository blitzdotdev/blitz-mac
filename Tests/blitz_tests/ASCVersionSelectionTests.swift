import Foundation
import Testing
@testable import Blitz

@MainActor
@Test func syncSelectedVersionPrefersEditableUpdateOverLiveVersion() {
    let manager = ASCManager()
    manager.appStoreVersions = [
        makeVersion(id: "live", versionString: "1.2.3", state: "READY_FOR_SALE", createdDate: "2026-03-20T00:00:00Z"),
        makeVersion(id: "draft", versionString: "1.2.4", state: "PREPARE_FOR_SUBMISSION", createdDate: "2026-03-21T00:00:00Z"),
    ]

    let selectedVersionId = manager.syncSelectedVersion()

    #expect(selectedVersionId == "draft")
    #expect(manager.selectedVersion?.id == "draft")
    #expect(manager.pendingVersionId == "draft")
    #expect(!manager.canCreateUpdate)
}

@MainActor
@Test func pendingVersionIdDoesNotFallBackToLiveVersion() {
    let manager = ASCManager()
    manager.appStoreVersions = [
        makeVersion(id: "live", versionString: "1.2.3", state: "READY_FOR_SALE", createdDate: "2026-03-20T00:00:00Z"),
    ]

    let selectedVersionId = manager.syncSelectedVersion()

    #expect(selectedVersionId == "live")
    #expect(manager.selectedVersion?.id == "live")
    #expect(manager.pendingVersionId == nil)
    #expect(manager.canCreateUpdate)
}

@MainActor
@Test func historicalRejectedVersionDoesNotOverrideNewerLiveVersion() {
    let manager = ASCManager()
    manager.appStoreVersions = [
        makeVersion(id: "live", versionString: "2.0", state: "READY_FOR_SALE", createdDate: "2026-03-20T00:00:00Z"),
        makeVersion(id: "rejected", versionString: "1.9", state: "REJECTED", createdDate: "2026-03-01T00:00:00Z"),
    ]

    let selectedVersionId = manager.syncSelectedVersion()

    #expect(selectedVersionId == "live")
    #expect(manager.selectedVersion?.id == "live")
    #expect(manager.currentUpdateVersion == nil)
    #expect(manager.pendingVersionId == nil)
    #expect(manager.canCreateUpdate)
}

@MainActor
@Test func historicalRejectedVersionDoesNotOverrideCurrentInFlightUpdate() {
    let manager = ASCManager()
    manager.appStoreVersions = [
        makeVersion(id: "review", versionString: "2.1", state: "IN_REVIEW", createdDate: "2026-03-21T00:00:00Z"),
        makeVersion(id: "live", versionString: "2.0", state: "READY_FOR_SALE", createdDate: "2026-03-20T00:00:00Z"),
        makeVersion(id: "rejected", versionString: "1.9", state: "REJECTED", createdDate: "2026-03-01T00:00:00Z"),
    ]

    let selectedVersionId = manager.syncSelectedVersion()

    #expect(selectedVersionId == "review")
    #expect(manager.selectedVersion?.id == "review")
    #expect(manager.currentUpdateVersion?.id == "review")
    #expect(manager.editableVersion == nil)
    #expect(!manager.canCreateUpdate)
    #expect(manager.newVersionCreationBlocker?.id == "review")
}

@MainActor
@Test func currentRejectedUpdateStillBlocksWhenNewerThanLiveVersion() {
    let manager = ASCManager()
    manager.appStoreVersions = [
        makeVersion(id: "rejected", versionString: "2.1", state: "REJECTED", createdDate: "2026-03-21T00:00:00Z"),
        makeVersion(id: "live", versionString: "2.0", state: "READY_FOR_SALE", createdDate: "2026-03-20T00:00:00Z"),
    ]

    let selectedVersionId = manager.syncSelectedVersion()

    #expect(selectedVersionId == "rejected")
    #expect(manager.selectedVersion?.id == "rejected")
    #expect(manager.currentUpdateVersion?.id == "rejected")
    #expect(manager.editableVersion?.id == "rejected")
    #expect(!manager.canCreateUpdate)
    #expect(manager.newVersionCreationBlocker?.id == "rejected")
}

@MainActor
@Test func newVersionCreationBlockerUsesExistingInFlightVersion() {
    let manager = ASCManager()
    manager.appStoreVersions = [
        makeVersion(id: "draft", versionString: "1.0.1", state: "PREPARE_FOR_SUBMISSION", createdDate: "2026-03-21T00:00:00Z"),
        makeVersion(id: "live", versionString: "1.0.0", state: "READY_FOR_SALE", createdDate: "2026-03-20T00:00:00Z"),
    ]

    #expect(manager.newVersionCreationBlocker?.id == "draft")
    #expect(manager.newVersionCreationBlockerMessage(desiredVersionString: "1.0.2")?
        .contains("version 1.0.1 in Prepare For Submission") == true)
}

@MainActor
@Test func submissionReadinessUsesSelectedVersionBuildInsteadOfLatestBuildListEntry() {
    let manager = ASCManager()
    manager.appStoreVersions = [
        makeVersion(id: "draft", versionString: "1.2.4", state: "PREPARE_FOR_SUBMISSION", createdDate: "2026-03-21T00:00:00Z"),
    ]
    manager.selectedVersionId = "draft"
    manager.builds = [
        makeBuild(id: "latest-build", version: "999"),
    ]
    manager.selectedVersionBuild = makeBuild(id: "attached-build", version: "123")

    let buildField = manager.submissionReadiness.fields.first { $0.label == "Build" }

    #expect(buildField?.value == "123")
}

@MainActor
@Test func overviewRejectionCardDoesNotFallBackToUnrelatedSelectedVersion() {
    let manager = ASCManager()
    manager.appStoreVersions = [
        makeVersion(id: "live", versionString: "2.0", state: "READY_FOR_SALE", createdDate: "2026-03-20T00:00:00Z"),
        makeVersion(id: "draft", versionString: "2.1", state: "PREPARE_FOR_SUBMISSION", createdDate: "2026-03-21T00:00:00Z"),
    ]
    manager.selectedVersionId = "live"
    manager.latestSubmissionItems = [
        makeSubmissionItem(id: "item-1", state: "REJECTED")
    ]

    #expect(manager.rejectionCardVersionForSelectedVersion(from: manager.appStoreVersions) == nil)
}

@MainActor
@Test func overviewRejectionCardUsesSelectedRejectedVersion() {
    let manager = ASCManager()
    manager.appStoreVersions = [
        makeVersion(id: "rejected", versionString: "2.1", state: "REJECTED", createdDate: "2026-03-21T00:00:00Z"),
        makeVersion(id: "live", versionString: "2.0", state: "READY_FOR_SALE", createdDate: "2026-03-20T00:00:00Z"),
    ]
    manager.selectedVersionId = "rejected"

    #expect(manager.rejectionCardVersionForSelectedVersion(from: manager.appStoreVersions)?.id == "rejected")
}

@MainActor
@Test func screenshotCacheSeparatesDifferentVersionsForSameLocale() {
    let manager = ASCManager()
    manager.appStoreVersions = [
        makeVersion(id: "v1", versionString: "1.0.0", state: "READY_FOR_SALE", createdDate: "2026-03-20T00:00:00Z"),
        makeVersion(id: "v2", versionString: "1.1.0", state: "PREPARE_FOR_SUBMISSION", createdDate: "2026-03-21T00:00:00Z"),
    ]

    manager.selectedVersionId = "v1"
    manager.updateScreenshotCache(
        locale: "en-US",
        sets: [makeScreenshotSet(id: "set-v1", displayType: "APP_IPHONE_67", count: 1)],
        screenshots: ["set-v1": [makeScreenshot(id: "shot-v1", fileName: "v1.png")]]
    )

    manager.selectedVersionId = "v2"
    manager.updateScreenshotCache(
        locale: "en-US",
        sets: [makeScreenshotSet(id: "set-v2", displayType: "APP_IPHONE_67", count: 1)],
        screenshots: ["set-v2": [makeScreenshot(id: "shot-v2", fileName: "v2.png")]]
    )

    manager.selectedVersionId = "v1"
    #expect(manager.screenshotSetsForLocale("en-US").map(\.id) == ["set-v1"])

    manager.selectedVersionId = "v2"
    #expect(manager.screenshotSetsForLocale("en-US").map(\.id) == ["set-v2"])
}

@MainActor
@Test func submissionReadinessRequiresWhatsNewForEveryUpdateLocalization() {
    let manager = ASCManager()
    manager.app = makeApp(primaryLocale: "en-US")
    manager.appStoreVersions = [
        makeVersion(id: "live", versionString: "1.0.0", state: "READY_FOR_SALE", createdDate: "2026-03-20T00:00:00Z"),
        makeVersion(id: "update", versionString: "1.0.1", state: "PREPARE_FOR_SUBMISSION", createdDate: "2026-03-21T00:00:00Z"),
    ]
    manager.selectedVersionId = "update"
    manager.localizations = [
        makeLocalization(id: "loc-gb", locale: "en-GB", whatsNew: nil),
        makeLocalization(id: "loc-us", locale: "en-US", whatsNew: ""),
    ]

    let missing = Set(manager.submissionReadiness.missingRequired.map(\.label))

    #expect(missing.contains("What's New (en-GB)"))
    #expect(missing.contains("What's New (en-US)"))
}

@MainActor
@Test func submissionReadinessDoesNotRequireWhatsNewForFirstRelease() {
    let manager = ASCManager()
    manager.app = makeApp(primaryLocale: "en-US")
    manager.appStoreVersions = [
        makeVersion(id: "first", versionString: "1.0.0", state: "PREPARE_FOR_SUBMISSION", createdDate: "2026-03-21T00:00:00Z"),
    ]
    manager.selectedVersionId = "first"
    manager.localizations = [
        makeLocalization(id: "loc-us", locale: "en-US", whatsNew: ""),
    ]

    let labels = Set(manager.submissionReadiness.fields.map(\.label))

    #expect(!labels.contains("What's New"))
    #expect(!labels.contains("What's New (en-US)"))
}

@MainActor
@Test func submissionReadinessShowsWhatsNewAsConfiguredWhenUpdateReleaseNotesAreFilled() {
    let manager = ASCManager()
    manager.app = makeApp(primaryLocale: "en-US")
    manager.appStoreVersions = [
        makeVersion(id: "live", versionString: "1.0.0", state: "READY_FOR_SALE", createdDate: "2026-03-20T00:00:00Z"),
        makeVersion(id: "update", versionString: "1.0.1", state: "PREPARE_FOR_SUBMISSION", createdDate: "2026-03-21T00:00:00Z"),
    ]
    manager.selectedVersionId = "update"
    manager.localizations = [
        makeLocalization(id: "loc-gb", locale: "en-GB", whatsNew: "Bug fixes."),
        makeLocalization(id: "loc-us", locale: "en-US", whatsNew: "Bug fixes."),
    ]

    let whatsNewField = manager.submissionReadiness.fields.first { $0.label == "What's New" }

    #expect(whatsNewField?.value == "Configured for 2 localization(s)")
}

private func makeVersion(
    id: String,
    versionString: String,
    state: String,
    createdDate: String
) -> ASCAppStoreVersion {
    ASCAppStoreVersion(
        id: id,
        attributes: ASCAppStoreVersion.Attributes(
            versionString: versionString,
            appStoreState: state,
            releaseType: nil,
            createdDate: createdDate,
            copyright: nil
        )
    )
}

private func makeBuild(id: String, version: String) -> ASCBuild {
    ASCBuild(
        id: id,
        attributes: ASCBuild.Attributes(
            version: version,
            uploadedDate: nil,
            processingState: "VALID",
            expirationDate: nil,
            expired: false,
            minOsVersion: nil
        )
    )
}

private func makeSubmissionItem(id: String, state: String) -> ASCReviewSubmissionItem {
    ASCReviewSubmissionItem(
        id: id,
        attributes: ASCReviewSubmissionItem.Attributes(
            state: state,
            resolved: nil,
            createdDate: nil
        ),
        relationships: nil
    )
}

private func makeApp(primaryLocale: String?) -> ASCApp {
    ASCApp(
        id: "app",
        attributes: ASCApp.Attributes(
            bundleId: "com.example.app",
            name: "Example",
            primaryLocale: primaryLocale,
            vendorNumber: nil,
            contentRightsDeclaration: nil
        )
    )
}

private func makeLocalization(
    id: String,
    locale: String,
    whatsNew: String?
) -> ASCVersionLocalization {
    ASCVersionLocalization(
        id: id,
        attributes: ASCVersionLocalization.Attributes(
            locale: locale,
            title: nil,
            subtitle: nil,
            description: "Description",
            keywords: "keywords",
            promotionalText: nil,
            marketingUrl: nil,
            supportUrl: "https://example.com/support",
            whatsNew: whatsNew
        )
    )
}

private func makeScreenshotSet(id: String, displayType: String, count: Int?) -> ASCScreenshotSet {
    ASCScreenshotSet(
        id: id,
        attributes: ASCScreenshotSet.Attributes(
            screenshotDisplayType: displayType,
            screenshotCount: count
        )
    )
}

private func makeScreenshot(id: String, fileName: String) -> ASCScreenshot {
    ASCScreenshot(
        id: id,
        attributes: ASCScreenshot.Attributes(
            fileName: fileName,
            fileSize: nil,
            imageAsset: nil,
            assetDeliveryState: nil
        )
    )
}

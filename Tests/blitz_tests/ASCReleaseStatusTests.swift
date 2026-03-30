import Foundation
import Testing
@testable import Blitz

@Test func dashboardStatusIgnoresOlderRejectedVersionAfterLiveRelease() {
    let status = ASCDashboardProjectStatus(versions: [
        makeVersion(id: "live", state: "READY_FOR_SALE", createdDate: "2026-03-20T00:00:00Z"),
        makeVersion(id: "rejected", state: "REJECTED", createdDate: "2026-03-01T00:00:00Z"),
    ])

    #expect(status.isLiveOnStore)
    #expect(!status.isPendingReview)
    #expect(!status.isRejected)
}

@Test func dashboardStatusCountsRejectedUpdateAlongsideLiveRelease() {
    let status = ASCDashboardProjectStatus(versions: [
        makeVersion(id: "rejected", state: "REJECTED", createdDate: "2026-03-21T00:00:00Z"),
        makeVersion(id: "live", state: "READY_FOR_SALE", createdDate: "2026-03-20T00:00:00Z"),
    ])

    #expect(status.isLiveOnStore)
    #expect(!status.isPendingReview)
    #expect(status.isRejected)
}

@Test func dashboardStatusCountsPendingReviewUpdateAlongsideLiveRelease() {
    let status = ASCDashboardProjectStatus(versions: [
        makeVersion(id: "review", state: "WAITING_FOR_REVIEW", createdDate: "2026-03-21T00:00:00Z"),
        makeVersion(id: "live", state: "READY_FOR_SALE", createdDate: "2026-03-20T00:00:00Z"),
    ])

    #expect(status.isLiveOnStore)
    #expect(status.isPendingReview)
    #expect(!status.isRejected)
}

@Test func releaseStatusSortsVersionsByNewestCreatedDateFirst() {
    let sorted = ASCReleaseStatus.sortedVersionsByRecency([
        makeVersion(id: "old", state: "READY_FOR_SALE", createdDate: "2026-03-01T00:00:00Z"),
        makeVersion(id: "new", state: "WAITING_FOR_REVIEW", createdDate: "2026-03-21T00:00:00Z"),
        makeVersion(id: "middle", state: "REJECTED", createdDate: "2026-03-10T00:00:00Z"),
    ])

    #expect(sorted.map(\.id) == ["new", "middle", "old"])
}

@Test func submissionHistoryMapsInvalidBinaryToSubmissionError() {
    #expect(ASCReleaseStatus.submissionHistoryEventType(forVersionState: "INVALID_BINARY") == .submissionError)
    #expect(ASCReleaseStatus.reviewSubmissionEventType(forVersionState: "INVALID_BINARY") == .submissionError)
}

@Test func reviewSubmissionStaysSubmittedForWaitingForReview() {
    #expect(ASCReleaseStatus.reviewSubmissionEventType(forVersionState: "WAITING_FOR_REVIEW") == .submitted)
}

@Test func appWallCurrentStatePrefersLiveOverNewerPrepareForSubmissionDraft() {
    let state = ASCReleaseStatus.appWallCurrentState(for: [
        makeVersion(id: "draft", state: "PREPARE_FOR_SUBMISSION", createdDate: "2026-03-21T00:00:00Z"),
        makeVersion(id: "live", state: "READY_FOR_SALE", createdDate: "2026-03-20T00:00:00Z"),
    ])

    #expect(state == "READY_FOR_SALE")
}

@Test func appWallCurrentStatePrefersCurrentPendingReviewUpdateOverLiveVersion() {
    let state = ASCReleaseStatus.appWallCurrentState(for: [
        makeVersion(id: "review", state: "IN_REVIEW", createdDate: "2026-03-21T00:00:00Z"),
        makeVersion(id: "live", state: "READY_FOR_SALE", createdDate: "2026-03-20T00:00:00Z"),
    ])

    #expect(state == "IN_REVIEW")
}

@Test func appWallCurrentStateFallsBackToNewestStateWhenNoLiveVersionExists() {
    let state = ASCReleaseStatus.appWallCurrentState(for: [
        makeVersion(id: "draft", state: "PREPARE_FOR_SUBMISSION", createdDate: "2026-03-21T00:00:00Z"),
    ])

    #expect(state == "PREPARE_FOR_SUBMISSION")
}

@Test func appWallCurrentVersionPrefersLiveVersionOverNewerDraft() {
    let version = ASCReleaseStatus.appWallCurrentVersion(for: [
        makeVersion(id: "draft", state: "PREPARE_FOR_SUBMISSION", createdDate: "2026-03-21T00:00:00Z"),
        makeVersion(id: "live", state: "READY_FOR_SALE", createdDate: "2026-03-20T00:00:00Z"),
    ])

    #expect(version?.id == "live")
}

@Test func appWallCurrentVersionPrefersCurrentPendingReviewUpdateOverOlderLiveVersion() {
    let version = ASCReleaseStatus.appWallCurrentVersion(for: [
        makeVersion(id: "review", state: "IN_REVIEW", createdDate: "2026-03-21T00:00:00Z"),
        makeVersion(id: "live", state: "READY_FOR_SALE", createdDate: "2026-03-20T00:00:00Z"),
    ])

    #expect(version?.id == "review")
}

private func makeVersion(id: String, state: String, createdDate: String) -> ASCAppStoreVersion {
    ASCAppStoreVersion(
        id: id,
        attributes: ASCAppStoreVersion.Attributes(
            versionString: id,
            appStoreState: state,
            releaseType: nil,
            createdDate: createdDate,
            copyright: nil
        )
    )
}

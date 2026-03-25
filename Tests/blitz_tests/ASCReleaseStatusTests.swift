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

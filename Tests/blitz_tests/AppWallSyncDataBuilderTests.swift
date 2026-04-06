import Foundation
import Testing
@testable import Blitz

@Test func testAppWallFeedbackPayloadOmitsReviewerDetailsWhenSharingIsDisabled() {
    let payload = AppWallSyncFeedbackPayload(
        versionString: "1.0.0",
        feedbackType: "rejection",
        rejectionReasons: ["5.2.5: Missing attribution"],
        reviewerMessage: "Please add attribution.",
        guidelineIds: ["5.2.5"],
        occurredAt: "2026-03-26T00:43:28.537Z",
        isPublic: false
    ).jsonObject

    #expect(payload["version_string"] as? String == "1.0.0")
    #expect(payload["feedback_type"] as? String == "rejection")
    #expect(payload["occurred_at"] as? String == "2026-03-26T00:43:28.537Z")
    #expect(payload["is_public"] as? Bool == false)
    #expect(payload["rejection_reasons"] == nil)
    #expect(payload["reviewer_message"] == nil)
    #expect(payload["guideline_ids"] == nil)
}

@Test func testAppWallFeedbackPayloadIncludesReviewerDetailsWhenSharingIsEnabled() {
    let payload = AppWallSyncFeedbackPayload(
        versionString: "1.0.0",
        feedbackType: "rejection",
        rejectionReasons: ["5.2.5: Missing attribution"],
        reviewerMessage: "Please add attribution.",
        guidelineIds: ["5.2.5"],
        occurredAt: "2026-03-26T00:43:28.537Z",
        isPublic: true
    ).jsonObject

    #expect(payload["is_public"] as? Bool == true)
    #expect(payload["rejection_reasons"] as? [String] == ["5.2.5: Missing attribution"])
    #expect(payload["reviewer_message"] as? String == "Please add attribution.")
    #expect(payload["guideline_ids"] as? [String] == ["5.2.5"])
}

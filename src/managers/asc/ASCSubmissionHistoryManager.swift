import Foundation

extension ASCManager {
    // Submission history is intentionally built only from facts we can defend:
    // real review submissions plus real Iris rejection cycles.
    func rebuildSubmissionHistory(appId _: String) {
        let submissionEvents = reviewSubmissions.compactMap { submission -> ASCSubmissionHistoryEvent? in
            let submittedAt = trimmed(submission.attributes.submittedDate)
            guard !submittedAt.isEmpty else { return nil }
            let versionId = reviewSubmissionItemsBySubmissionId[submission.id]?
                .compactMap(\.appStoreVersionId)
                .first
            let versionString = versionString(
                for: versionId,
                submissionId: submission.id
            ) ?? "Unknown"
            return ASCSubmissionHistoryEvent(
                id: "submission:\(submission.id)",
                versionId: versionId,
                versionString: versionString,
                eventType: .submitted,
                appleState: submission.attributes.state,
                occurredAt: submittedAt,
                source: .reviewSubmission,
                accuracy: .exact,
                submissionId: submission.id,
                note: nil
            )
        }

        let rejectionEvents = irisFeedbackCycles.compactMap { cycle -> ASCSubmissionHistoryEvent? in
            let versionString = cycle.versionString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !versionString.isEmpty else { return nil }
            return ASCSubmissionHistoryEvent(
                id: "iris:\(cycle.id)",
                versionId: versionId(
                    for: versionString,
                    submissionId: cycle.submissionId
                ),
                versionString: versionString,
                eventType: .rejected,
                appleState: "REJECTED",
                occurredAt: cycle.occurredAt,
                source: .irisFeedback,
                accuracy: .derived,
                submissionId: cycle.submissionId,
                note: cycle.primaryReasonSection
            )
        }

        submissionHistoryEvents = (submissionEvents + rejectionEvents)
            .sorted { lhs, rhs in
                historyDate(lhs.occurredAt) > historyDate(rhs.occurredAt)
            }
    }

    func refreshReviewSubmissionData(appId: String, service: AppStoreConnectService) async {
        let submissions = ((try? await service.fetchReviewSubmissions(appId: appId)) ?? []).filter {
            !trimmed($0.attributes.submittedDate).isEmpty
        }
        reviewSubmissions = submissions

        guard !submissions.isEmpty else {
            reviewSubmissionItemsBySubmissionId = [:]
            latestSubmissionItems = []
            return
        }

        var itemsBySubmissionId: [String: [ASCReviewSubmissionItem]] = [:]
        await withTaskGroup(of: (String, [ASCReviewSubmissionItem]).self) { group in
            for submission in submissions {
                group.addTask {
                    let items = (try? await service.fetchReviewSubmissionItems(submissionId: submission.id)) ?? []
                    return (submission.id, items)
                }
            }

            for await (submissionId, items) in group {
                itemsBySubmissionId[submissionId] = items
            }
        }

        reviewSubmissionItemsBySubmissionId = itemsBySubmissionId
        latestSubmissionItems = itemsBySubmissionId[submissions.first?.id ?? ""] ?? []
    }

    private func historyDate(_ iso: String?) -> Date {
        guard let iso else { return .distantPast }
        let formatterWithFractionalSeconds = ISO8601DateFormatter()
        formatterWithFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatter = ISO8601DateFormatter()
        return formatterWithFractionalSeconds.date(from: iso) ?? formatter.date(from: iso) ?? .distantPast
    }

    private func versionString(
        for versionId: String?,
        submissionId: String?
    ) -> String? {
        if let versionId,
           let version = appStoreVersions.first(where: { $0.id == versionId }) {
            return version.attributes.versionString
        }
        return irisFeedbackCycles.first(where: { $0.submissionId == submissionId })?.versionString
    }

    private func versionId(
        for versionString: String,
        submissionId: String?
    ) -> String? {
        if let submissionId,
           let versionId = reviewSubmissionItemsBySubmissionId[submissionId]?
            .compactMap(\.appStoreVersionId)
            .first {
            return versionId
        }
        if let version = appStoreVersions.first(where: { $0.attributes.versionString == versionString }) {
            return version.id
        }
        return nil
    }
}

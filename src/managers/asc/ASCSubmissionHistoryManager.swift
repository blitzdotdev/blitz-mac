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
        await ASCUpdateLogger.shared.event("review_submission_refresh_started", metadata: [
            "appId": appId,
        ])

        let submissions: [ASCReviewSubmission]
        do {
            submissions = try await service.fetchReviewSubmissions(appId: appId).filter {
                !trimmed($0.attributes.submittedDate).isEmpty
            }
        } catch {
            reviewSubmissions = []
            reviewSubmissionItemsBySubmissionId = [:]
            latestSubmissionItems = []
            await logDataFetchFailure("review_submission_refresh_failed", error: error, metadata: [
                "appId": appId,
            ])
            return
        }
        reviewSubmissions = submissions

        guard !submissions.isEmpty else {
            reviewSubmissionItemsBySubmissionId = [:]
            latestSubmissionItems = []
            await ASCUpdateLogger.shared.event("review_submission_refresh_succeeded", metadata: [
                "appId": appId,
                "submissionCount": "0",
            ])
            return
        }

        var itemsBySubmissionId: [String: [ASCReviewSubmissionItem]] = [:]
        var itemFailures: [String] = []
        await withTaskGroup(of: (String, [ASCReviewSubmissionItem], String?).self) { group in
            for submission in submissions {
                group.addTask {
                    do {
                        let items = try await service.fetchReviewSubmissionItems(submissionId: submission.id)
                        return (submission.id, items, nil)
                    } catch {
                        return (submission.id, [], error.localizedDescription)
                    }
                }
            }

            for await (submissionId, items, failure) in group {
                itemsBySubmissionId[submissionId] = items
                if let failure {
                    itemFailures.append("\(submissionId): \(failure)")
                }
            }
        }

        reviewSubmissionItemsBySubmissionId = itemsBySubmissionId
        latestSubmissionItems = itemsBySubmissionId[submissions.first?.id ?? ""] ?? []
        await ASCUpdateLogger.shared.event("review_submission_refresh_succeeded", metadata: [
            "appId": appId,
            "itemFailureCount": String(itemFailures.count),
            "submissionCount": String(submissions.count),
        ])
        if !itemFailures.isEmpty {
            await ASCUpdateLogger.shared.snapshot(
                label: "review_submission_items_partial_failure",
                body: itemFailures.joined(separator: "\n")
                    + "\n\n"
                    + diagnosticSnapshot(reason: "review_submission_items_partial_failure")
            )
        }
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

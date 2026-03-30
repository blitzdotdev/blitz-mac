import Foundation

struct AppWallSyncData {
    let ascApp: ASCApp
    let versions: [ASCAppStoreVersion]
    let events: [AppWallSyncEventPayload]
    let feedbacks: [AppWallSyncFeedbackPayload]
}

struct AppWallSyncEventPayload {
    let ascSubmissionId: String?
    let versionString: String
    let eventType: String
    let occurredAt: String
    let accuracy: String?
    let source: String?
    let notes: String?

    init?(historyEvent: ASCSubmissionHistoryEvent) {
        let versionString = historyEvent.versionString.trimmingCharacters(in: .whitespacesAndNewlines)
        let occurredAt = historyEvent.occurredAt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !versionString.isEmpty, !occurredAt.isEmpty else { return nil }

        self.ascSubmissionId = historyEvent.submissionId
        self.versionString = versionString
        self.eventType = historyEvent.eventType.rawValue
        self.occurredAt = occurredAt
        self.accuracy = historyEvent.accuracy.rawValue
        self.source = historyEvent.source.rawValue
        self.notes = historyEvent.note
    }

    var jsonObject: [String: Any] {
        var payload: [String: Any] = [
            "version_string": versionString,
            "event_type": eventType,
            "occurred_at": occurredAt,
        ]
        if let ascSubmissionId, !ascSubmissionId.isEmpty { payload["asc_submission_id"] = ascSubmissionId }
        if let accuracy, !accuracy.isEmpty { payload["accuracy"] = accuracy }
        if let source, !source.isEmpty { payload["source"] = source }
        if let notes, !notes.isEmpty { payload["notes"] = notes }
        return payload
    }
}

struct AppWallSyncFeedbackPayload {
    let versionString: String
    let feedbackType: String
    let rejectionReasons: [String]
    let reviewerMessage: String?
    let guidelineIds: [String]
    let occurredAt: String

    var jsonObject: [String: Any] {
        var payload: [String: Any] = [
            "version_string": versionString,
            "feedback_type": feedbackType,
            "occurred_at": occurredAt,
        ]
        if !rejectionReasons.isEmpty { payload["rejection_reasons"] = rejectionReasons }
        if let reviewerMessage, !reviewerMessage.isEmpty { payload["reviewer_message"] = reviewerMessage }
        if !guidelineIds.isEmpty { payload["guideline_ids"] = guidelineIds }
        return payload
    }
}

enum AppWallSyncDataBuilder {
    @MainActor
    static func build(
        app: ASCApp,
        versions: [ASCAppStoreVersion],
        service: AppStoreConnectService,
        irisSession: IrisSession?
    ) async -> AppWallSyncData {
        // Reuse the canonical ASC/Iris history builders instead of maintaining a
        // second sync-only transformation path with different edge cases.
        let ascManager = ASCManager()
        ascManager.app = app
        ascManager.appStoreVersions = versions
        ascManager.loadCachedFeedback(appId: app.id, versionString: nil)

        await ascManager.refreshReviewSubmissionData(appId: app.id, service: service)

        if let irisSession {
            ascManager.irisService = IrisService(session: irisSession)
            ascManager.irisSessionState = .valid
            await ascManager.fetchRejectionFeedback()
        } else {
            ascManager.rebuildSubmissionHistory(appId: app.id)
        }

        let events = ascManager.submissionHistoryEvents.compactMap(AppWallSyncEventPayload.init)
        let feedbacks = buildFeedbackPayloads(cycles: ascManager.irisFeedbackCycles, versions: versions)

        return AppWallSyncData(
            ascApp: app,
            versions: versions,
            events: events,
            feedbacks: feedbacks
        )
    }

    private static func buildFeedbackPayloads(
        cycles: [IrisFeedbackCycle],
        versions: [ASCAppStoreVersion],
    ) -> [AppWallSyncFeedbackPayload] {
        cycles
            .compactMap { cycle in
                let versionString = cycle.versionString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !versionString.isEmpty else { return nil }

                let rejectionReasons = cycle.reasons.compactMap { reason -> String? in
                    let section = reason.section.trimmingCharacters(in: .whitespacesAndNewlines)
                    let description = reason.description.trimmingCharacters(in: .whitespacesAndNewlines)

                    if !section.isEmpty && !description.isEmpty {
                        return "\(section): \(description)"
                    }
                    if !section.isEmpty { return section }
                    if !description.isEmpty { return description }
                    return nil
                }
                let guidelineIds = cycle.guidelineIds
                let reviewerMessage = cycle.reviewerMessage

                guard !rejectionReasons.isEmpty || !guidelineIds.isEmpty || reviewerMessage != nil else {
                    return nil
                }

                let feedbackType = versions
                    .first(where: { $0.attributes.versionString == versionString })?
                    .attributes.appStoreState?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased() == "METADATA_REJECTED" ? "metadata_rejection" : "rejection"

                return AppWallSyncFeedbackPayload(
                    versionString: versionString,
                    feedbackType: feedbackType,
                    rejectionReasons: rejectionReasons,
                    reviewerMessage: reviewerMessage,
                    guidelineIds: guidelineIds,
                    occurredAt: cycle.occurredAt
                )
            }
            .sorted { irisArchiveSortDate($0.occurredAt) > irisArchiveSortDate($1.occurredAt) }
    }
}

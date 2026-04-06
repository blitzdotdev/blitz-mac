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
    let appleState: String?
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
        self.appleState = historyEvent.appleState?.trimmingCharacters(in: .whitespacesAndNewlines)
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
        if let appleState, !appleState.isEmpty { payload["apple_state"] = appleState }
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
    let isPublic: Bool

    var jsonObject: [String: Any] {
        var payload: [String: Any] = [
            "version_string": versionString,
            "feedback_type": feedbackType,
            "occurred_at": occurredAt,
            "is_public": isPublic,
        ]
        guard isPublic else { return payload }
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

        let events = buildEventPayloads(ascManager: ascManager, versions: versions)
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
        let shareReviewerFeedback = UserDefaults.standard.object(forKey: "appWallShareReviewerFeedback") as? Bool ?? true

        return cycles
            .compactMap { cycle -> AppWallSyncFeedbackPayload? in
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
                    occurredAt: cycle.occurredAt,
                    isPublic: shareReviewerFeedback
                )
            }
            .sorted { irisArchiveSortDate($0.occurredAt) > irisArchiveSortDate($1.occurredAt) }
    }

    @MainActor
    private static func buildEventPayloads(
        ascManager: ASCManager,
        versions: [ASCAppStoreVersion]
    ) -> [AppWallSyncEventPayload] {
        let historyEvents = ascManager.submissionHistoryEvents
        let syntheticLiveEvents = syntheticLiveCompletionEvents(
            historyEvents: historyEvents,
            reviewSubmissions: ascManager.reviewSubmissions,
            submissionItemsBySubmissionId: ascManager.reviewSubmissionItemsBySubmissionId,
            versions: versions
        )

        return (historyEvents + syntheticLiveEvents)
            .sorted { sortDate($0.occurredAt) > sortDate($1.occurredAt) }
            .compactMap(AppWallSyncEventPayload.init)
    }

    @MainActor
    private static func syntheticLiveCompletionEvents(
        historyEvents: [ASCSubmissionHistoryEvent],
        reviewSubmissions: [ASCReviewSubmission],
        submissionItemsBySubmissionId: [String: [ASCReviewSubmissionItem]],
        versions: [ASCAppStoreVersion]
    ) -> [ASCSubmissionHistoryEvent] {
        let closedSubmissionIds = Set(
            historyEvents.compactMap { event -> String? in
                guard let submissionId = event.submissionId?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !submissionId.isEmpty else { return nil }
                switch event.eventType {
                case .accepted, .live, .rejected, .withdrawn, .removed, .submissionError:
                    return submissionId
                case .submitted, .inReview, .processing:
                    return nil
                }
            }
        )

        return versions.compactMap { version in
            guard ASCReleaseStatus.isLive(version.attributes.appStoreState) else { return nil }

            let matchingSubmissions = reviewSubmissions
                .filter { submission in
                    submissionItemsBySubmissionId[submission.id]?
                        .contains(where: { $0.appStoreVersionId == version.id }) == true
                }
                .sorted { lhs, rhs in
                    sortDate(lhs.attributes.submittedDate) > sortDate(rhs.attributes.submittedDate)
                }

            guard let openSubmission = matchingSubmissions.first(where: { !closedSubmissionIds.contains($0.id) }) else {
                return nil
            }

            let submittedAt = openSubmission.attributes.submittedDate?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !submittedAt.isEmpty else { return nil }

            return ASCSubmissionHistoryEvent(
                id: "synthetic-live:\(openSubmission.id)",
                versionId: version.id,
                versionString: version.attributes.versionString,
                eventType: .live,
                appleState: version.attributes.appStoreState,
                occurredAt: submittedAt,
                source: .reviewSubmission,
                accuracy: .derived,
                submissionId: openSubmission.id,
                note: nil
            )
        }
    }

    private static func sortDate(_ iso: String?) -> Date {
        guard let iso else { return .distantPast }
        let formatterWithFractionalSeconds = ISO8601DateFormatter()
        formatterWithFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatter = ISO8601DateFormatter()
        return formatterWithFractionalSeconds.date(from: iso) ?? formatter.date(from: iso) ?? .distantPast
    }
}

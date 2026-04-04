import Foundation

// MARK: - Review Manager
// Extension containing review-related functionality for ASCManager

extension ASCManager {
    // MARK: - Review Contact Updates

    func updateReviewContact(_ attributes: [String: Any]) async {
        guard let service else { return }
        guard let versionId = selectedVersion?.id else { return }
        let startedAt = Date()
        writeError = nil
        do {
            try await service.createOrPatchReviewDetail(versionId: versionId, attributes: attributes)
            reviewDetail = await fetchReviewDetailLogged(
                service: service,
                versionId: versionId,
                context: "review_contact_update"
            )
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "review.contact.update",
                success: true,
                startedAt: startedAt
            )
        } catch {
            writeError = error.localizedDescription
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "review.contact.update",
                success: false,
                startedAt: startedAt
            )
        }
    }
}

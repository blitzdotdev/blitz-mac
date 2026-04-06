import Foundation

// MARK: - Review Manager
// Extension containing review-related functionality for ASCManager

extension ASCManager {
    // MARK: - Age Rating

    func updateAgeRating(_ attributes: [String: Any]) async {
        guard let service else { return }
        guard let id = ageRatingDeclaration?.id else { return }
        let startedAt = Date()
        writeError = nil
        do {
            try await service.patchAgeRating(id: id, attributes: attributes)
            if let infoId = appInfo?.id {
                ageRatingDeclaration = await fetchAgeRatingLogged(
                    service: service,
                    appInfoId: infoId,
                    context: "age_rating_update"
                )
            }
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "age_rating.update",
                success: true,
                startedAt: startedAt
            )
        } catch {
            writeError = error.localizedDescription
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "age_rating.update",
                success: false,
                startedAt: startedAt
            )
        }
    }

    // MARK: - Review Contact Updates

    func updateReviewContact(_ attributes: [String: Any]) async {
        guard let service else { return }
        guard let versionId = selectedVersion?.id else { return }
        let startedAt = Date()
        writeError = nil
        do {
            reviewDetail = try await service.createOrPatchReviewDetail(versionId: versionId, attributes: attributes)
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

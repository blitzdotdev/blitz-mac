import Foundation

extension ASCManager {
    func logDataFetchFailure(
        _ event: String,
        error: Error,
        metadata: [String: String] = [:]
    ) async {
        var payload = metadata
        payload["error"] = error.localizedDescription
        if case let ASCError.httpError(statusCode, _) = error {
            payload["statusCode"] = String(statusCode)
        }

        await ASCUpdateLogger.shared.event(event, metadata: payload)
        await ASCUpdateLogger.shared.snapshot(
            label: "\(event)_app_state",
            body: diagnosticSnapshot(reason: event, error: error)
        )
    }

    func diagnosticSnapshot(reason: String, error: Error? = nil) -> String {
        var lines: [String] = []
        lines.append("reason: \(reason)")
        if let error {
            lines.append("error: \(error.localizedDescription)")
        }

        if let appState {
            lines.append("navigation:")
            lines.append("  activeProjectId: \(appState.activeProjectId ?? "nil")")
            lines.append("  activeTab: \(appState.activeTab.rawValue)")
            lines.append("  activeAppSubTab: \(appState.activeAppSubTab.rawValue)")
            lines.append("  activeDashboardSubTab: \(appState.activeDashboardSubTab.rawValue)")
            if let project = appState.activeProject {
                lines.append("  activeProject.name: \(project.name)")
                lines.append("  activeProject.path: \(project.path)")
                lines.append("  activeProject.bundleId: \(project.metadata.bundleIdentifier ?? "nil")")
            }
        }

        lines.append("asc:")
        lines.append("  credentialsLoaded: \(credentials != nil)")
        lines.append("  serviceReady: \(service != nil)")
        lines.append("  loadedProjectId: \(loadedProjectId ?? "nil")")
        lines.append("  isLoadingApp: \(isLoadingApp)")
        lines.append("  isSubmitting: \(isSubmitting)")
        lines.append("  isCreatingVersion: \(isCreatingVersion)")
        lines.append("  writeError: \(writeError ?? "nil")")
        lines.append("  submissionError: \(submissionError ?? "nil")")
        lines.append("  versionCreationError: \(versionCreationError ?? "nil")")
        lines.append("  selectedVersionId: \(selectedVersionId ?? "nil")")
        lines.append("  selectedVersionBuildId: \(selectedVersionBuild?.id ?? "nil")")
        lines.append("  selectedVersionBuildNumber: \(selectedVersionBuild?.attributes.version ?? "nil")")
        lines.append("  selectedStoreListingLocale: \(selectedStoreListingLocale ?? "nil")")
        lines.append("  selectedScreenshotsLocale: \(selectedScreenshotsLocale ?? "nil")")
        lines.append("  selectedBuildId: \(selectedBuildId ?? "nil")")
        lines.append("  app: \(renderApp())")
        lines.append("  selectedVersion: \(renderVersion(selectedVersion))")
        lines.append("  liveVersion: \(renderVersion(liveVersion))")
        lines.append("  editableVersion: \(renderVersion(editableVersion))")
        lines.append("  currentUpdateVersion: \(renderVersion(currentUpdateVersion))")
        lines.append("  appStoreVersions:")
        lines.append(contentsOf: appStoreVersions.map { "    - \(renderVersion($0))" })
        lines.append("  localizations:")
        lines.append(contentsOf: localizations.map { localization in
            let whatsNew = localization.attributes.whatsNew?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return "    - id=\(localization.id) locale=\(localization.attributes.locale) whatsNewEmpty=\(whatsNew.isEmpty)"
        })
        lines.append("  reviewDetail: \(renderReviewDetail())")
        lines.append("  ageRatingId: \(ageRatingDeclaration?.id ?? "nil")")
        lines.append("  monetizationStatus: \(monetizationStatus ?? "nil")")
        lines.append("  currentAppPricePointId: \(currentAppPricePointId ?? "nil")")
        lines.append("  scheduledAppPricePointId: \(scheduledAppPricePointId ?? "nil")")
        lines.append("  scheduledAppPriceEffectiveDate: \(scheduledAppPriceEffectiveDate ?? "nil")")
        lines.append("  appPricePoints:")
        lines.append(contentsOf: appPricePoints.map { pricePoint in
            "    - id=\(pricePoint.id) customerPrice=\(pricePoint.attributes.customerPrice ?? "nil")"
        })
        lines.append("  inAppPurchases:")
        lines.append(contentsOf: inAppPurchases.map { item in
            "    - id=\(item.id) name=\(item.attributes.name ?? "nil") state=\(item.attributes.state ?? "nil")"
        })
        lines.append("  subscriptionGroups:")
        lines.append(contentsOf: subscriptionGroups.map { group in
            "    - id=\(group.id) referenceName=\(group.attributes.referenceName ?? "nil")"
        })
        lines.append("  subscriptionsPerGroup:")
        for groupId in subscriptionsPerGroup.keys.sorted() {
            let subscriptions = subscriptionsPerGroup[groupId] ?? []
            lines.append("    - groupId=\(groupId)")
            lines.append(contentsOf: subscriptions.map { subscription in
                "      * id=\(subscription.id) name=\(subscription.attributes.name ?? "nil") state=\(subscription.attributes.state ?? "nil")"
            })
        }
        lines.append("  loadedTabs: \(loadedTabs.map(\.rawValue).sorted().joined(separator: ","))")
        lines.append("  loadingFields: \(overviewReadinessLoadingFields.sorted().joined(separator: ","))")
        lines.append("  tabErrors:")
        for key in tabError.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            lines.append("    - \(key.rawValue): \(tabError[key] ?? "nil")")
        }
        lines.append("  pendingFormTabs: \(pendingFormValues.keys.sorted().joined(separator: ","))")
        lines.append("  reviewSubmissions:")
        lines.append(contentsOf: reviewSubmissions.map { submission in
            "    - id=\(submission.id) state=\(submission.attributes.state ?? "nil") submittedDate=\(submission.attributes.submittedDate ?? "nil")"
        })
        lines.append("  latestSubmissionItems:")
        lines.append(contentsOf: latestSubmissionItems.map { item in
            "    - id=\(item.id) versionId=\(item.appStoreVersionId ?? "nil")"
        })
        lines.append("  submissionHistoryEvents:")
        lines.append(contentsOf: submissionHistoryEvents.map { event in
            "    - id=\(event.id) type=\(event.eventType.rawValue) version=\(event.versionString) occurredAt=\(event.occurredAt)"
        })

        return lines.joined(separator: "\n")
    }

    private func renderApp() -> String {
        guard let app else { return "nil" }
        return "id=\(app.id) name=\(app.name) bundleId=\(app.bundleId) primaryLocale=\(app.primaryLocale ?? "nil")"
    }

    private func renderVersion(_ version: ASCAppStoreVersion?) -> String {
        guard let version else { return "nil" }
        return "id=\(version.id) version=\(version.attributes.versionString) state=\(version.attributes.appStoreState ?? "nil") createdDate=\(version.attributes.createdDate ?? "nil")"
    }

    private func renderReviewDetail() -> String {
        guard let reviewDetail else { return "nil" }
        return "id=\(reviewDetail.id) firstName=\(reviewDetail.attributes.contactFirstName ?? "nil") lastName=\(reviewDetail.attributes.contactLastName ?? "nil") email=\(reviewDetail.attributes.contactEmail ?? "nil") phone=\(reviewDetail.attributes.contactPhone ?? "nil") demoRequired=\(reviewDetail.attributes.demoAccountRequired?.description ?? "nil")"
    }

    func fetchReviewDetailLogged(
        service: AppStoreConnectService,
        versionId: String,
        context: String
    ) async -> ASCReviewDetail? {
        await ASCUpdateLogger.shared.event("review_detail_fetch_started", metadata: [
            "context": context,
            "versionId": versionId,
        ])

        do {
            let detail = try await service.fetchReviewDetail(versionId: versionId)
            await ASCUpdateLogger.shared.event("review_detail_fetch_succeeded", metadata: [
                "context": context,
                "reviewDetailId": detail.id,
                "versionId": versionId,
            ])
            return detail
        } catch {
            await logDataFetchFailure("review_detail_fetch_failed", error: error, metadata: [
                "context": context,
                "versionId": versionId,
            ])
            return nil
        }
    }

    func fetchAgeRatingLogged(
        service: AppStoreConnectService,
        appInfoId: String,
        context: String
    ) async -> ASCAgeRatingDeclaration? {
        await ASCUpdateLogger.shared.event("age_rating_fetch_started", metadata: [
            "appInfoId": appInfoId,
            "context": context,
        ])

        do {
            let declaration = try await service.fetchAgeRating(appInfoId: appInfoId)
            await ASCUpdateLogger.shared.event("age_rating_fetch_succeeded", metadata: [
                "ageRatingId": declaration.id,
                "appInfoId": appInfoId,
                "context": context,
            ])
            return declaration
        } catch {
            await logDataFetchFailure("age_rating_fetch_failed", error: error, metadata: [
                "appInfoId": appInfoId,
                "context": context,
            ])
            return nil
        }
    }

    func fetchAppPricingStateLogged(
        service: AppStoreConnectService,
        appId: String,
        context: String
    ) async -> ASCAppPricingState? {
        await ASCUpdateLogger.shared.event("pricing_state_fetch_started", metadata: [
            "appId": appId,
            "context": context,
        ])

        do {
            let state = try await service.fetchAppPricingState(appId: appId)
            await ASCUpdateLogger.shared.event("pricing_state_fetch_succeeded", metadata: [
                "appId": appId,
                "context": context,
                "currentPricePointId": state.currentPricePointId ?? "nil",
                "scheduledPricePointId": state.scheduledPricePointId ?? "nil",
            ])
            return state
        } catch {
            await logDataFetchFailure("pricing_state_fetch_failed", error: error, metadata: [
                "appId": appId,
                "context": context,
            ])
            return nil
        }
    }

    func fetchPricingConfiguredLogged(
        service: AppStoreConnectService,
        appId: String,
        context: String
    ) async -> Bool {
        await ASCUpdateLogger.shared.event("pricing_configured_fetch_started", metadata: [
            "appId": appId,
            "context": context,
        ])

        do {
            let configured = try await service.fetchPricingConfiguredDetailed(appId: appId)
            await ASCUpdateLogger.shared.event("pricing_configured_fetch_succeeded", metadata: [
                "appId": appId,
                "configured": configured ? "true" : "false",
                "context": context,
            ])
            return configured
        } catch {
            await logDataFetchFailure("pricing_configured_fetch_failed", error: error, metadata: [
                "appId": appId,
                "context": context,
            ])
            return false
        }
    }
}

import Foundation

// MARK: - Release Manager
// Extension containing release-related functionality for ASCManager

extension ASCManager {
    private static let versionScopedTabs: Set<AppTab> = [
        .app,
        .storeListing,
        .screenshots,
        .appDetails,
        .review,
    ]

    // MARK: - Version Selection

    var liveVersion: ASCAppStoreVersion? {
        ASCReleaseStatus.currentLiveVersion(for: appStoreVersions)
    }

    var currentUpdateVersion: ASCAppStoreVersion? {
        ASCReleaseStatus.currentUpdateVersion(for: appStoreVersions)
    }

    var editableVersion: ASCAppStoreVersion? {
        ASCReleaseStatus.currentEditableVersion(for: appStoreVersions)
    }

    var selectedVersion: ASCAppStoreVersion? {
        if let selectedVersionId,
           let match = appStoreVersions.first(where: { $0.id == selectedVersionId }) {
            return match
        }
        return ASCReleaseStatus.defaultSelectedVersion(for: appStoreVersions)
    }

    var selectedVersionIsEditable: Bool {
        ASCReleaseStatus.isEditable(selectedVersion?.attributes.appStoreState)
    }

    var canCreateVersion: Bool {
        app?.id != nil
    }

    var canCreateUpdate: Bool {
        liveVersion != nil && currentUpdateVersion == nil
    }

    /// ASC only allows a new version to be created when there is no existing
    /// in-flight App Store version for the app.
    var newVersionCreationBlocker: ASCAppStoreVersion? {
        currentUpdateVersion
    }

    /// The current non-live version ID, if one exists.
    var pendingVersionId: String? {
        currentUpdateVersion?.id
    }

    private var submittableVersionId: String? {
        if let selectedVersion,
           ASCReleaseStatus.isEditable(selectedVersion.attributes.appStoreState) {
            return selectedVersion.id
        }
        return editableVersion?.id
    }

    func version(matching identifier: String?) -> ASCAppStoreVersion? {
        guard let identifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty else {
            return nil
        }
        return appStoreVersions.first(where: {
            $0.id == identifier || $0.attributes.versionString == identifier
        })
    }

    func newVersionCreationBlockerMessage(desiredVersionString: String? = nil) -> String? {
        guard let blocker = newVersionCreationBlocker else { return nil }
        let blockerState = ASCReleaseStatus.normalize(blocker.attributes.appStoreState)
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
        let desiredSuffix: String
        if let desiredVersionString,
           !desiredVersionString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            desiredSuffix = " before creating \(desiredVersionString)"
        } else {
            desiredSuffix = ""
        }
        return "App Store Connect already has version \(blocker.attributes.versionString) in \(blockerState). "
            + "Use that version or finish, submit, or remove it\(desiredSuffix)."
    }

    @discardableResult
    func syncSelectedVersion(preferredVersionId: String? = nil) -> String? {
        let preferred = preferredVersionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let preferred,
           appStoreVersions.contains(where: { $0.id == preferred }) {
            selectedVersionId = preferred
            return preferred
        }

        if let selectedVersionId,
           appStoreVersions.contains(where: { $0.id == selectedVersionId }) {
            return selectedVersionId
        }

        let resolved = currentUpdateVersion?.id
            ?? editableVersion?.id
            ?? liveVersion?.id
            ?? ASCReleaseStatus.defaultSelectedVersion(for: appStoreVersions)?.id
        selectedVersionId = resolved
        return resolved
    }

    func prepareForVersionSelection(_ versionId: String?) {
        let trimmedVersionId = versionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedVersionId != selectedVersionId else { return }

        // Version switches invalidate every cache whose contents come from a
        // version-scoped ASC resource, so the next tab refresh starts cleanly.
        let previousVersionId = selectedVersionId
        selectedVersionId = trimmedVersionId
        selectedVersionBuild = nil
        localizations = []
        selectedStoreListingLocale = nil
        screenshotSetsByLocale = [:]
        screenshotsByLocale = [:]
        selectedScreenshotsLocale = nil
        reviewDetail = nil
        writeError = nil
        versionCreationError = nil

        for tab in Self.versionScopedTabs {
            cancelBackgroundHydration(for: tab)
            loadedTabs.remove(tab)
            tabLoadedAt.removeValue(forKey: tab)
            isLoadingTab.removeValue(forKey: tab)
            tabError.removeValue(forKey: tab)
        }

        Task {
            await ASCUpdateLogger.shared.event("select_version", metadata: [
                "previousVersionId": previousVersionId ?? "nil",
                "versionId": trimmedVersionId ?? "nil",
            ])
        }
    }

    func refreshSelectedVersionBuild() async {
        guard let service else {
            selectedVersionBuild = nil
            return
        }
        guard let versionId = selectedVersion?.id else {
            selectedVersionBuild = nil
            return
        }
        selectedVersionBuild = try? await service.fetchBuildAttachedToVersion(versionId: versionId)
    }

    // MARK: - Build Attachment

    func attachBuild(buildId: String) async {
        guard let service else { return }
        guard let versionId = submittableVersionId else {
            writeError = "No editable app store version found to attach a build to."
            await ASCUpdateLogger.shared.event("attach_build_failed", metadata: [
                "buildId": buildId,
                "reason": "no_editable_version",
            ])
            return
        }

        let startedAt = Date()
        await ASCUpdateLogger.shared.event("attach_build_started", metadata: [
            "buildId": buildId,
            "versionId": versionId,
        ])

        writeError = nil
        do {
            try await service.attachBuild(versionId: versionId, buildId: buildId)
            selectedVersionBuild = builds.first(where: { $0.id == buildId })
            await ASCUpdateLogger.shared.event("attach_build_succeeded", metadata: [
                "buildId": buildId,
                "versionId": versionId,
            ])
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "build.attach",
                success: true,
                startedAt: startedAt
            )
        } catch {
            writeError = error.localizedDescription
            await ASCUpdateLogger.shared.event("attach_build_failed", metadata: [
                "buildId": buildId,
                "error": error.localizedDescription,
                "versionId": versionId,
            ])
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "build.attach",
                success: false,
                startedAt: startedAt
            )
        }
    }

    // MARK: - Version Creation

    func createUpdateVersion(
        versionString: String,
        platform: ProjectPlatform,
        copyFromVersionId: String? = nil,
        copyMetadata: Bool = true,
        copyReviewDetail: Bool = true,
        attachBuildId: String? = nil
    ) async {
        guard let service, let appId = app?.id else {
            await ASCUpdateLogger.shared.event("create_update_failed", metadata: [
                "reason": "missing_service_or_app",
                "versionString": versionString,
            ])
            return
        }

        let trimmedVersion = versionString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVersion.isEmpty else {
            versionCreationError = "Version string is required."
            await ASCUpdateLogger.shared.event("create_update_failed", metadata: [
                "reason": "empty_version_string",
            ])
            return
        }

        if appStoreVersions.contains(where: {
            $0.attributes.versionString.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedVersion
        }) {
            versionCreationError = "Version \(trimmedVersion) already exists."
            await ASCUpdateLogger.shared.event("create_update_failed", metadata: [
                "reason": "duplicate_version",
                "versionString": trimmedVersion,
            ])
            return
        }

        if let blockerMessage = newVersionCreationBlockerMessage(desiredVersionString: trimmedVersion),
           let blocker = newVersionCreationBlocker {
            versionCreationError = blockerMessage
            await ASCUpdateLogger.shared.event("create_update_blocked", metadata: [
                "blockingState": blocker.attributes.appStoreState ?? "unknown",
                "blockingVersionId": blocker.id,
                "blockingVersionString": blocker.attributes.versionString,
                "versionString": trimmedVersion,
            ])
            return
        }

        isCreatingVersion = true
        versionCreationError = nil
        let startedAt = Date()
        await ASCUpdateLogger.shared.event("create_update_started", metadata: [
            "appId": appId,
            "attachBuildId": attachBuildId ?? "nil",
            "copyFromVersionId": copyFromVersionId ?? "nil",
            "copyMetadata": copyMetadata ? "true" : "false",
            "copyReviewDetail": copyReviewDetail ? "true" : "false",
            "versionString": trimmedVersion,
        ])

        do {
            // Snapshot any source data up front so the copy phase is deterministic
            // even if the selected version changes while the task is running.
            let sourceVersion = version(matching: copyFromVersionId)
                ?? liveVersion
                ?? currentUpdateVersion
                ?? appStoreVersions.first

            let sourceLocalizations: [ASCVersionLocalization]
            if copyMetadata, let sourceVersion {
                sourceLocalizations = try await service.fetchLocalizations(versionId: sourceVersion.id)
            } else {
                sourceLocalizations = []
            }

            let sourceReviewDetail: ASCReviewDetail?
            if copyReviewDetail, let sourceVersion {
                sourceReviewDetail = try? await service.fetchReviewDetail(versionId: sourceVersion.id)
            } else {
                sourceReviewDetail = nil
            }

            // Create the new version first, then hydrate it with copied metadata
            // and the optional attached build.
            let createdVersion = try await service.createAppStoreVersion(
                appId: appId,
                versionString: trimmedVersion,
                platform: platform.ascPlatformValue,
                copyright: sourceVersion?.attributes.copyright,
                releaseType: sourceVersion?.attributes.releaseType
            )
            await ASCUpdateLogger.shared.event("create_update_created_version", metadata: [
                "sourceVersionId": sourceVersion?.id ?? "nil",
                "versionId": createdVersion.id,
                "versionString": trimmedVersion,
            ])

            if copyMetadata {
                for localization in sourceLocalizations {
                    do {
                        _ = try await service.createVersionLocalization(
                            versionId: createdVersion.id,
                            locale: localization.attributes.locale,
                            fields: versionLocalizationFieldsToCopy(localization)
                        )
                        await ASCUpdateLogger.shared.event("create_update_copied_localization", metadata: [
                            "locale": localization.attributes.locale,
                            "versionId": createdVersion.id,
                        ])
                    } catch let ascError as ASCError where ascError.isConflict {
                        await ASCUpdateLogger.shared.event("create_update_skipped_localization", metadata: [
                            "locale": localization.attributes.locale,
                            "reason": "conflict",
                            "versionId": createdVersion.id,
                        ])
                        continue
                    }
                }
            }

            if copyReviewDetail, let sourceReviewDetail {
                try await service.createOrPatchReviewDetail(
                    versionId: createdVersion.id,
                    attributes: reviewDetailAttributesToCopy(sourceReviewDetail)
                )
                await ASCUpdateLogger.shared.event("create_update_copied_review_detail", metadata: [
                    "versionId": createdVersion.id,
                ])
            }

            if let attachBuildId,
               !attachBuildId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await service.attachBuild(versionId: createdVersion.id, buildId: attachBuildId)
                await ASCUpdateLogger.shared.event("create_update_attached_build", metadata: [
                    "buildId": attachBuildId,
                    "versionId": createdVersion.id,
                ])
            }

            appStoreVersions = try await service.fetchAppStoreVersions(appId: appId)
            prepareForVersionSelection(createdVersion.id)
            syncSelectedVersion(preferredVersionId: createdVersion.id)
            showCreateUpdateSheet = false
            await refreshTabData(.app)
            await ASCUpdateLogger.shared.event("create_update_succeeded", metadata: [
                "versionId": createdVersion.id,
                "versionString": trimmedVersion,
            ])
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "version.create",
                success: true,
                startedAt: startedAt
            )
        } catch {
            versionCreationError = error.localizedDescription
            await ASCUpdateLogger.shared.event("create_update_failed", metadata: [
                "error": error.localizedDescription,
                "versionString": trimmedVersion,
            ])
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "version.create",
                success: false,
                startedAt: startedAt
            )
        }

        isCreatingVersion = false
    }

    // MARK: - Submission

    func submitForReview(attachBuildId: String? = nil) async {
        guard let service else { return }
        guard let appId = app?.id, let versionId = submittableVersionId else {
            submissionError = "No editable app store version is selected."
            await ASCUpdateLogger.shared.event("submit_for_review_failed", metadata: [
                "reason": "no_editable_version",
            ])
            return
        }
        isSubmitting = true
        submissionError = nil
        let startedAt = Date()
        await ASCUpdateLogger.shared.event("submit_for_review_started", metadata: [
            "appId": appId,
            "attachBuildId": attachBuildId ?? "nil",
            "versionId": versionId,
        ])
        do {
            // Attach build if specified
            if let buildId = attachBuildId {
                try await service.attachBuild(versionId: versionId, buildId: buildId)
                selectedVersionBuild = builds.first(where: { $0.id == buildId })
            }
            try await service.submitForReview(appId: appId, versionId: versionId)
            isSubmitting = false
            await refreshTabData(.app)
            await ASCUpdateLogger.shared.event("submit_for_review_succeeded", metadata: [
                "appId": appId,
                "versionId": versionId,
            ])
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "submit.review",
                success: true,
                startedAt: startedAt
            )
        } catch {
            isSubmitting = false
            submissionError = error.localizedDescription
            await ASCUpdateLogger.shared.event("submit_for_review_failed", metadata: [
                "error": error.localizedDescription,
                "versionId": versionId,
            ])
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "submit.review",
                success: false,
                startedAt: startedAt
            )
        }
    }

    // MARK: - Localization Flushing

    func flushPendingLocalizations() async {
        guard let service else { return }
        let appInfoLocFieldNames: Set<String> = ["name", "title", "subtitle", "privacyPolicyUrl"]
        for (tab, fields) in pendingFormValues {
            if tab == "storeListing" {
                let locale = activeStoreListingLocale()
                var versionLocFields: [String: String] = [:]
                var infoLocFields: [String: String] = [:]
                for (field, value) in fields {
                    if appInfoLocFieldNames.contains(field) {
                        let apiField = (field == "title") ? "name" : field
                        infoLocFields[apiField] = value
                    } else {
                        versionLocFields[field] = value
                    }
                }
                if !versionLocFields.isEmpty, let locId = storeListingLocalization(locale: locale)?.id {
                    try? await service.patchLocalization(id: locId, fields: versionLocFields)
                }
                if !infoLocFields.isEmpty, let infoLocId = appInfoLocalizationForLocale(locale)?.id {
                    try? await service.patchAppInfoLocalization(id: infoLocId, fields: infoLocFields)
                }
            }
        }
        pendingFormValues = [:]
    }
}

private extension ASCManager {
    func versionLocalizationFieldsToCopy(_ localization: ASCVersionLocalization) -> [String: String] {
        var fields: [String: String] = [:]
        if let title = localization.attributes.title, !title.isEmpty {
            fields["title"] = title
        }
        if let subtitle = localization.attributes.subtitle, !subtitle.isEmpty {
            fields["subtitle"] = subtitle
        }
        if let description = localization.attributes.description, !description.isEmpty {
            fields["description"] = description
        }
        if let keywords = localization.attributes.keywords, !keywords.isEmpty {
            fields["keywords"] = keywords
        }
        if let promotionalText = localization.attributes.promotionalText, !promotionalText.isEmpty {
            fields["promotionalText"] = promotionalText
        }
        if let marketingUrl = localization.attributes.marketingUrl, !marketingUrl.isEmpty {
            fields["marketingUrl"] = marketingUrl
        }
        if let supportUrl = localization.attributes.supportUrl, !supportUrl.isEmpty {
            fields["supportUrl"] = supportUrl
        }
        return fields
    }

    func reviewDetailAttributesToCopy(_ detail: ASCReviewDetail) -> [String: Any] {
        var attributes: [String: Any] = [:]
        let source = detail.attributes
        if let contactFirstName = source.contactFirstName, !contactFirstName.isEmpty {
            attributes["contactFirstName"] = contactFirstName
        }
        if let contactLastName = source.contactLastName, !contactLastName.isEmpty {
            attributes["contactLastName"] = contactLastName
        }
        if let contactPhone = source.contactPhone, !contactPhone.isEmpty {
            attributes["contactPhone"] = contactPhone
        }
        if let contactEmail = source.contactEmail, !contactEmail.isEmpty {
            attributes["contactEmail"] = contactEmail
        }
        if let demoAccountRequired = source.demoAccountRequired {
            attributes["demoAccountRequired"] = demoAccountRequired
        }
        if let demoAccountName = source.demoAccountName, !demoAccountName.isEmpty {
            attributes["demoAccountName"] = demoAccountName
        }
        if let demoAccountPassword = source.demoAccountPassword, !demoAccountPassword.isEmpty {
            attributes["demoAccountPassword"] = demoAccountPassword
        }
        if let notes = source.notes, !notes.isEmpty {
            attributes["notes"] = notes
        }
        return attributes
    }
}

private extension ProjectPlatform {
    var ascPlatformValue: String {
        switch self {
        case .iOS:
            return "IOS"
        case .macOS:
            return "MAC_OS"
        }
    }
}

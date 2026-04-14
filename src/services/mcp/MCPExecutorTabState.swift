import Foundation

extension MCPExecutor {
    // MARK: - Tab State Tool

    private static let ageRatingBooleanFieldReaders: [(String, (ASCAgeRatingDeclaration.Attributes) -> Bool?)] = [
        ("gambling", { $0.gambling }),
        ("messagingAndChat", { $0.messagingAndChat }),
        ("unrestrictedWebAccess", { $0.unrestrictedWebAccess }),
        ("userGeneratedContent", { $0.userGeneratedContent }),
        ("advertising", { $0.advertising }),
        ("lootBox", { $0.lootBox }),
        ("healthOrWellnessTopics", { $0.healthOrWellnessTopics }),
        ("parentalControls", { $0.parentalControls }),
        ("ageAssurance", { $0.ageAssurance }),
    ]

    private static let ageRatingEnumFieldReaders: [(String, (ASCAgeRatingDeclaration.Attributes) -> String?)] = [
        ("alcoholTobaccoOrDrugUseOrReferences", { $0.alcoholTobaccoOrDrugUseOrReferences }),
        ("contests", { $0.contests }),
        ("gamblingSimulated", { $0.gamblingSimulated }),
        ("gunsOrOtherWeapons", { $0.gunsOrOtherWeapons }),
        ("horrorOrFearThemes", { $0.horrorOrFearThemes }),
        ("matureOrSuggestiveThemes", { $0.matureOrSuggestiveThemes }),
        ("medicalOrTreatmentInformation", { $0.medicalOrTreatmentInformation }),
        ("profanityOrCrudeHumor", { $0.profanityOrCrudeHumor }),
        ("sexualContentGraphicAndNudity", { $0.sexualContentGraphicAndNudity }),
        ("sexualContentOrNudity", { $0.sexualContentOrNudity }),
        ("violenceCartoonOrFantasy", { $0.violenceCartoonOrFantasy }),
        ("violenceRealistic", { $0.violenceRealistic }),
        ("violenceRealisticProlongedGraphicOrSadistic", { $0.violenceRealisticProlongedGraphicOrSadistic }),
    ]

    private static let reviewContactFieldOrder = [
        "contactFirstName",
        "contactLastName",
        "contactEmail",
        "contactPhone",
        "notes",
        "demoAccountRequired",
        "demoAccountName",
        "demoAccountPassword",
    ]

    private static func overviewReviewDraftKey(for label: String) -> String? {
        switch label {
        case "Review Contact First Name":
            return "contactFirstName"
        case "Review Contact Last Name":
            return "contactLastName"
        case "Review Contact Email":
            return "contactEmail"
        case "Review Contact Phone":
            return "contactPhone"
        case "Demo Account Name":
            return "demoAccountName"
        case "Demo Account Password":
            return "demoAccountPassword"
        default:
            return nil
        }
    }

    static func ageRatingStatePayload(
        ageRating: ASCAgeRatingDeclaration?,
        isSaved: Bool,
        pendingDraft: [String: String]?
    ) -> [String: Any]? {
        let hasPendingDraft = !(pendingDraft?.isEmpty ?? true)
        guard ageRating != nil || hasPendingDraft else { return nil }

        let attributes = ageRating?.attributes
        var payload: [String: Any] = [
            "isSaved": isSaved,
            "hasPendingChanges": hasPendingDraft,
        ]
        if let ageRating {
            payload["id"] = ageRating.id
        }

        var missingRequired: [String] = []
        for (field, reader) in ageRatingBooleanFieldReaders {
            if let attributes, let value = reader(attributes) {
                payload[field] = value
            } else {
                payload[field] = NSNull()
                missingRequired.append(field)
            }
        }
        for (field, reader) in ageRatingEnumFieldReaders {
            if let attributes, let value = reader(attributes), !value.isEmpty {
                payload[field] = value
            } else {
                payload[field] = NSNull()
                missingRequired.append(field)
            }
        }

        payload["missingRequired"] = missingRequired
        if let pendingDraft, !pendingDraft.isEmpty {
            payload["draftValues"] = pendingDraft
        }
        return payload
    }

    static func reviewContactFieldPayload(from attributes: [String: Any]) -> [String: Any] {
        var payload: [String: Any] = [:]
        for field in reviewContactFieldOrder {
            if field == "demoAccountRequired" {
                payload[field] = attributes[field] as? Bool ?? false
            } else {
                payload[field] = reviewContactStringValue(attributes[field]) ?? ""
            }
        }
        return payload
    }

    static func reviewContactStatePayload(
        reviewDetail: ASCReviewDetail?,
        pendingDraft: [String: String]?
    ) -> [String: Any]? {
        let hasPendingDraft = !(pendingDraft?.isEmpty ?? true)
        guard reviewDetail != nil || hasPendingDraft else { return nil }

        let persisted = mergedReviewContactAttributes(reviewDetail: reviewDetail, draft: [:])
        let effective = mergedReviewContactAttributes(reviewDetail: reviewDetail, draft: pendingDraft ?? [:])
        let persistedMissingRequired = missingRequiredReviewContactFields(from: persisted)

        var payload = reviewContactFieldPayload(from: effective)
        payload["savedToASC"] = !hasPendingDraft
        payload["hasPendingChanges"] = hasPendingDraft
        payload["missingRequired"] = missingRequiredReviewContactFields(from: effective)
        payload["missingRequiredPersisted"] = persistedMissingRequired
        if let reviewDetail {
            payload["id"] = reviewDetail.id
        }
        payload["persisted"] = reviewContactFieldPayload(from: persisted)
        if let pendingDraft, !pendingDraft.isEmpty {
            payload["pendingDraft"] = pendingDraft
        }
        return payload
    }

    static func overviewSubmissionReadinessPayload(
        readiness: SubmissionReadiness,
        reviewDetail: ASCReviewDetail?,
        pendingFormValues: [String: [String: String]]
    ) -> [String: Any] {
        let pendingReviewDraft = pendingFormValues["review.contact"] ?? [:]
        let effectiveReviewContact = mergedReviewContactAttributes(
            reviewDetail: reviewDetail,
            draft: pendingReviewDraft
        )
        let effectiveDemoRequired = effectiveReviewContact["demoAccountRequired"] as? Bool == true

        var effectiveFields = readiness.fields
        if effectiveDemoRequired {
            let existingLabels = Set(effectiveFields.map(\.label))
            if !existingLabels.contains("Demo Account Name") {
                effectiveFields.append(.init(label: "Demo Account Name", value: nil))
            }
            if !existingLabels.contains("Demo Account Password") {
                effectiveFields.append(.init(label: "Demo Account Password", value: nil))
            }
        }

        var fieldEntries: [[String: Any]] = []
        var missingRequiredConsideringDrafts: [String] = []

        for field in effectiveFields {
            let draftKey = overviewReviewDraftKey(for: field.label)
            let hasPendingChange = draftKey.map { pendingReviewDraft[$0] != nil } ?? false
            let effectiveValue: String?
            if let draftKey, let value = reviewContactStringValue(effectiveReviewContact[draftKey]) {
                effectiveValue = value
            } else {
                effectiveValue = field.value
            }

            let persistedFilled = field.value != nil && !(field.value?.isEmpty ?? true)
            let effectiveFilled = effectiveValue != nil && !(effectiveValue?.isEmpty ?? true)
            if field.required && !field.isLoading && !effectiveFilled {
                missingRequiredConsideringDrafts.append(field.label)
            }

            var entry: [String: Any] = [
                "label": field.label,
                "value": effectiveValue ?? NSNull(),
                "required": field.required,
                "filled": persistedFilled,
                "isLoading": field.isLoading,
                "savedToASC": !hasPendingChange,
            ]
            if hasPendingChange {
                entry["source"] = "draft"
                entry["hasPendingChanges"] = true
                entry["persistedValue"] = field.value ?? NSNull()
                entry["filledConsideringDrafts"] = effectiveFilled
            }
            if let hint = field.hint {
                entry["hint"] = hint
            }
            fieldEntries.append(entry)
        }

        let missingRequiredPersisted = readiness.missingRequired.map(\.label)

        return [
            "isComplete": readiness.isComplete,
            "isCompleteConsideringDrafts": missingRequiredConsideringDrafts.isEmpty,
            "fields": fieldEntries,
            "missingRequired": missingRequiredPersisted,
            "missingRequiredPersisted": missingRequiredPersisted,
            "missingRequiredConsideringDrafts": missingRequiredConsideringDrafts,
            "hasPendingDrafts": !pendingFormValues.isEmpty,
        ]
    }

    @MainActor
    func versionStatePayload(_ version: ASCAppStoreVersion?) -> [String: Any]? {
        guard let version else { return nil }
        var payload: [String: Any] = [
            "id": version.id,
            "versionString": version.attributes.versionString,
            "state": version.attributes.appStoreState ?? "unknown",
        ]
        if let createdDate = version.attributes.createdDate {
            payload["createdDate"] = createdDate
        }
        if let releaseType = version.attributes.releaseType {
            payload["releaseType"] = releaseType
        }
        return payload
    }

    func executeGetTabState(_ args: [String: Any]) async throws -> [String: Any] {
        let tabStr = args["tab"] as? String
        let tab: AppTab
        if let tabStr {
            if tabStr == "ascOverview" || tabStr == "overview" {
                tab = .app
            } else if let parsed = MCPAppInformationCompatibility.resolveAppTab(tabStr) {
                tab = parsed
            } else {
                tab = await MainActor.run { appState.activeTab }
            }
        } else {
            tab = await MainActor.run { appState.activeTab }
        }

        if tab == .app {
            await appState.ascManager.syncOverviewSubmissionReadiness(forceRefresh: true)
        }

        var result = await MainActor.run { () -> [String: Any] in
            let asc = appState.ascManager
            var value: [String: Any] = [
                "tab": tab.rawValue,
                "isLoading": asc.isLoadingTab[tab] ?? false,
            ]
            if let error = asc.tabError[tab] { value["error"] = error }
            if let writeErr = asc.writeError { value["writeError"] = writeErr }
            if tab.isASCTab, let app = asc.app {
                value["app"] = ["id": app.id, "name": app.name, "bundleId": app.bundleId]
            }
            return value
        }

        let tabData = await MainActor.run { () -> [String: Any] in
            let projectId = appState.activeProjectId
            return tabStateData(for: tab, asc: appState.ascManager, projectId: projectId)
        }
        for (key, value) in tabData {
            result[key] = value
        }

        return mcpJSON(result)
    }

    /// Extract tab-specific state data. Must be called on MainActor.
    @MainActor
    func tabStateData(for tab: AppTab, asc: ASCManager, projectId: String?) -> [String: Any] {
        switch tab {
        case .app:
            if let projectId {
                asc.checkAppIcon(projectId: projectId)
            }
            return tabStateASCOverview(asc)
        case .appInformation:
            return tabStateAppInformation(asc, projectId: projectId)
        case .review:
            return tabStateReview(asc)
        case .screenshots:
            return tabStateScreenshots(asc)
        case .reviews:
            return tabStateReviews(asc)
        case .builds:
            return tabStateBuilds(asc)
        case .groups:
            return tabStateGroups(asc)
        case .betaInfo:
            return tabStateBetaInfo(asc)
        case .feedback:
            return tabStateFeedback(asc)
        default:
            return ["note": "No structured state available for this tab"]
        }
    }

    @MainActor
    func tabStateASCOverview(_ asc: ASCManager) -> [String: Any] {
        let readiness = asc.submissionReadiness
        var result: [String: Any] = [
            "submissionReadiness": Self.overviewSubmissionReadinessPayload(
                readiness: readiness,
                reviewDetail: asc.reviewDetail,
                pendingFormValues: asc.pendingFormValues
            ),
            "totalVersions": asc.appStoreVersions.count,
            "isSubmitting": asc.isSubmitting,
            "canCreateUpdate": asc.canCreateUpdate,
            "selectedVersionIsEditable": asc.selectedVersionIsEditable,
        ]
        if let version = asc.appStoreVersions.first {
            result["latestVersion"] = [
                "id": version.id,
                "versionString": version.attributes.versionString,
                "state": version.attributes.appStoreState ?? "unknown"
            ]
        }
        if let selectedVersion = versionStatePayload(asc.selectedVersion) {
            result["selectedVersion"] = selectedVersion
        }
        if let liveVersion = versionStatePayload(asc.liveVersion) {
            result["liveVersion"] = liveVersion
        }
        if let currentUpdateVersion = versionStatePayload(asc.currentUpdateVersion) {
            result["currentUpdateVersion"] = currentUpdateVersion
        }
        if let editableVersion = versionStatePayload(asc.editableVersion) {
            result["editableVersion"] = editableVersion
        }
        if let selectedBuild = asc.selectedVersionBuild {
            result["selectedVersionBuild"] = [
                "id": selectedBuild.id,
                "version": selectedBuild.attributes.version,
                "processingState": selectedBuild.attributes.processingState ?? "unknown",
                "uploadedDate": selectedBuild.attributes.uploadedDate ?? "",
            ]
        }
        if let error = asc.submissionError {
            result["submissionError"] = error
        }
        if let cycle = asc.latestFeedbackCycle(forVersionString: nil) {
            result["rejectionFeedback"] = [
                "version": cycle.versionString ?? "",
                "reasonCount": cycle.reasons.count,
                "messageCount": cycle.messages.count,
                "cycleCount": asc.irisFeedbackCycles.count,
                "hint": "Use get_rejection_feedback tool for full details"
            ]
        }
        return result
    }

    @MainActor
    func tabStateAppInformation(_ asc: ASCManager, projectId: String?) -> [String: Any] {
        let selectedLocale = asc.activeAppInformationLocale() ?? ""
        let localization = asc.appInformationLocalization(locale: selectedLocale)
        let infoLoc = asc.appInfoLocalizationForLocale(selectedLocale)
        let localizationState: [String: Any] = [
            "locale": localization?.attributes.locale ?? "",
            "name": infoLoc?.attributes.name ?? localization?.attributes.title ?? "",
            "subtitle": infoLoc?.attributes.subtitle ?? localization?.attributes.subtitle ?? "",
            "description": localization?.attributes.description ?? "",
            "keywords": localization?.attributes.keywords ?? "",
            "promotionalText": localization?.attributes.promotionalText ?? "",
            "marketingUrl": localization?.attributes.marketingUrl ?? "",
            "supportUrl": localization?.attributes.supportUrl ?? "",
            "whatsNew": localization?.attributes.whatsNew ?? "",
            "privacyPolicyUrl": infoLoc?.attributes.privacyPolicyUrl ?? "",
        ]
        let detailsState: [String: Any] = [
            "copyright": asc.selectedVersion?.attributes.copyright ?? "",
            "primaryCategory": asc.appInfo?.primaryCategoryId ?? "",
            "contentRightsDeclaration": asc.app?.contentRightsDeclaration ?? "",
        ]

        var result: [String: Any] = [
            "selectedLocale": selectedLocale,
            "availableLocales": asc.localizations.map(\.attributes.locale),
            "localization": localizationState,
            "privacyPolicyUrl": infoLoc?.attributes.privacyPolicyUrl ?? "",
            "details": detailsState,
            "appInfo": [
                "primaryCategory": detailsState["primaryCategory"] ?? "",
                "contentRightsDeclaration": detailsState["contentRightsDeclaration"] ?? "",
            ],
            "hasAppInfoLocalization": infoLoc != nil,
            "localeCount": asc.localizations.count,
            "versionCount": asc.appStoreVersions.count,
            "canCreateUpdate": asc.canCreateUpdate,
        ]
        if let projectId {
            let metadata = ProjectStorage().readMetadata(projectId: projectId)
            result["teamId"] = metadata?.teamId ?? ""
        }
        if let latestVersion = asc.appStoreVersions.first {
            result["latestVersion"] = [
                "versionString": latestVersion.attributes.versionString,
                "state": latestVersion.attributes.appStoreState ?? "unknown"
            ]
        }
        if let selectedVersion = versionStatePayload(asc.selectedVersion) {
            result["selectedVersion"] = selectedVersion
        }
        return result
    }

    @MainActor
    func tabStateReview(_ asc: ASCManager) -> [String: Any] {
        var result: [String: Any] = [:]

        if let ageRating = Self.ageRatingStatePayload(
            ageRating: asc.ageRatingDeclaration,
            isSaved: asc.ageRatingIsConfigured,
            pendingDraft: asc.pendingFormValues["review.ageRating"]
        ) {
            result["ageRating"] = ageRating
        }

        if let reviewContact = Self.reviewContactStatePayload(
            reviewDetail: asc.reviewDetail,
            pendingDraft: asc.pendingFormValues["review.contact"]
        ) {
            result["reviewContact"] = reviewContact
        }

        result["builds"] = asc.builds.prefix(10).map { build -> [String: Any] in
            [
                "id": build.id,
                "version": build.attributes.version,
                "processingState": build.attributes.processingState ?? "unknown",
                "uploadedDate": build.attributes.uploadedDate ?? ""
            ]
        }
        result["canCreateUpdate"] = asc.canCreateUpdate
        if let selectedVersion = versionStatePayload(asc.selectedVersion) {
            result["selectedVersion"] = selectedVersion
        }
        if let selectedBuild = asc.selectedVersionBuild {
            result["selectedVersionBuild"] = [
                "id": selectedBuild.id,
                "version": selectedBuild.attributes.version,
                "processingState": selectedBuild.attributes.processingState ?? "unknown",
                "uploadedDate": selectedBuild.attributes.uploadedDate ?? "",
            ]
        }
        return result
    }

    @MainActor
    func tabStateScreenshots(_ asc: ASCManager) -> [String: Any] {
        let selectedLocale = asc.selectedScreenshotsLocale ?? asc.localizations.first?.attributes.locale ?? ""
        let screenshotSets = asc.screenshotSetsForLocale(selectedLocale)
        let screenshots = asc.screenshotsForLocale(selectedLocale)
        let displayTypes = asc.orderedKnownScreenshotDisplayTypes(for: selectedLocale)
        let sets = screenshotSets.map { set -> [String: Any] in
            var value: [String: Any] = ["id": set.id, "displayType": set.attributes.screenshotDisplayType]
            if let shots = screenshots[set.id] {
                value["screenshotCount"] = shots.count
                value["screenshots"] = shots.map {
                    ["id": $0.id, "fileName": $0.attributes.fileName ?? ""]
                }
            }
            return value
        }
        let tracks = displayTypes.map { displayType -> [String: Any] in
            let currentTrack = asc.trackSlotsForDisplayType(displayType, locale: selectedLocale)
            let savedTrack = asc.savedTrackStateForDisplayType(displayType, locale: selectedLocale)
            let slots = currentTrack.enumerated().map { index, slot -> [String: Any] in
                let savedSlot = savedTrack[index]
                return [
                    "index": index,
                    "slotIndex": index + 1,
                    "id": slot?.id as Any,
                    "source": slot == nil ? "empty" : (slot?.isFromASC == true ? "asc" : "local"),
                    "fileName": slot?.ascScreenshot?.attributes.fileName
                        ?? slot?.localPath.map { ($0 as NSString).lastPathComponent } as Any,
                    "localPath": slot?.localPath as Any,
                    "isFromASC": slot?.isFromASC as Any,
                    "isSynced": slot != nil && slot?.id == savedSlot?.id,
                    "hasError": slot?.ascScreenshot?.hasError ?? false,
                    "errorDescription": slot?.ascScreenshot?.errorDescription as Any,
                ]
            }
            return [
                "displayType": displayType,
                "filledSlotCount": currentTrack.compactMap { $0 }.count,
                "hasUnsavedChanges": asc.hasUnsavedChanges(displayType: displayType, locale: selectedLocale),
                "slots": slots,
            ]
        }
        var result: [String: Any] = [
            "selectedLocale": selectedLocale,
            "availableLocales": asc.localizations.map(\.attributes.locale),
            "screenshotSets": sets,
            "displayTypes": displayTypes,
            "tracks": tracks,
            "localeCount": asc.localizations.count,
            "canCreateUpdate": asc.canCreateUpdate,
        ]
        if let selectedVersion = versionStatePayload(asc.selectedVersion) {
            result["selectedVersion"] = selectedVersion
        }
        return result
    }

    @MainActor
    func tabStateReviews(_ asc: ASCManager) -> [String: Any] {
        let reviews = asc.customerReviews.prefix(20).map { review -> [String: Any] in
            [
                "id": review.id,
                "title": review.attributes.title ?? "",
                "body": review.attributes.body ?? "",
                "rating": review.attributes.rating,
                "reviewerNickname": review.attributes.reviewerNickname ?? ""
            ]
        }
        return ["reviews": reviews, "totalReviews": asc.customerReviews.count]
    }

    @MainActor
    func tabStateBuilds(_ asc: ASCManager) -> [String: Any] {
        let builds = asc.builds.prefix(20).map { build -> [String: Any] in
            [
                "id": build.id,
                "version": build.attributes.version,
                "processingState": build.attributes.processingState ?? "unknown",
                "uploadedDate": build.attributes.uploadedDate ?? ""
            ]
        }
        return ["builds": builds]
    }

    @MainActor
    func tabStateGroups(_ asc: ASCManager) -> [String: Any] {
        let groups = asc.betaGroups.map { group -> [String: Any] in
            [
                "id": group.id,
                "name": group.attributes.name,
                "isInternalGroup": group.attributes.isInternalGroup ?? false
            ]
        }
        return ["betaGroups": groups]
    }

    @MainActor
    func tabStateBetaInfo(_ asc: ASCManager) -> [String: Any] {
        let localizations = asc.betaLocalizations.map { localization -> [String: Any] in
            [
                "id": localization.id,
                "locale": localization.attributes.locale,
                "description": localization.attributes.description ?? ""
            ]
        }
        return ["betaLocalizations": localizations]
    }

    @MainActor
    func tabStateFeedback(_ asc: ASCManager) -> [String: Any] {
        var items: [[String: Any]] = []
        for (buildId, feedbackItems) in asc.betaFeedback {
            for item in feedbackItems {
                items.append([
                    "buildId": buildId,
                    "id": item.id,
                    "comment": item.attributes.comment ?? "",
                    "timestamp": item.attributes.timestamp ?? ""
                ])
            }
        }
        return ["feedback": items, "selectedBuildId": asc.selectedBuildId ?? ""]
    }
}

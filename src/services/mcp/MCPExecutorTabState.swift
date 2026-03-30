import Foundation

extension MCPExecutor {
    // MARK: - Tab State Tool

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
            } else if let parsed = AppTab(rawValue: tabStr) {
                tab = parsed
            } else {
                tab = await MainActor.run { appState.activeTab }
            }
        } else {
            tab = await MainActor.run { appState.activeTab }
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

        if tab == .app {
            await appState.ascManager.refreshSubmissionReadinessData()
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
        case .storeListing:
            return tabStateStoreListing(asc)
        case .appDetails:
            return tabStateAppDetails(asc)
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
        var fields: [[String: Any]] = []
        for field in readiness.fields {
            let filled = field.value != nil && !(field.value?.isEmpty ?? true)
            var entry: [String: Any] = [
                "label": field.label,
                "value": field.value as Any,
                "required": field.required,
                "filled": filled
            ]
            if let hint = field.hint {
                entry["hint"] = hint
            }
            fields.append(entry)
        }
        var result: [String: Any] = [
            "submissionReadiness": [
                "isComplete": readiness.isComplete,
                "fields": fields,
                "missingRequired": readiness.missingRequired.map { $0.label }
            ],
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
    func tabStateStoreListing(_ asc: ASCManager) -> [String: Any] {
        let selectedLocale = asc.activeStoreListingLocale() ?? ""
        let localization = asc.storeListingLocalization(locale: selectedLocale)
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
            "whatsNew": localization?.attributes.whatsNew ?? ""
        ]

        var result: [String: Any] = [
            "selectedLocale": selectedLocale,
            "availableLocales": asc.localizations.map(\.attributes.locale),
            "localization": localizationState,
            "privacyPolicyUrl": infoLoc?.attributes.privacyPolicyUrl ?? "",
            "hasAppInfoLocalization": infoLoc != nil,
            "localeCount": asc.localizations.count,
            "canCreateUpdate": asc.canCreateUpdate,
        ]
        if let selectedVersion = versionStatePayload(asc.selectedVersion) {
            result["selectedVersion"] = selectedVersion
        }
        return result
    }

    @MainActor
    func tabStateAppDetails(_ asc: ASCManager) -> [String: Any] {
        var result: [String: Any] = [
            "appInfo": [
                "primaryCategory": asc.appInfo?.primaryCategoryId ?? "",
                "contentRightsDeclaration": asc.app?.contentRightsDeclaration ?? ""
            ],
            "versionCount": asc.appStoreVersions.count,
            "canCreateUpdate": asc.canCreateUpdate,
        ]
        if let version = asc.appStoreVersions.first {
            result["latestVersion"] = [
                "versionString": version.attributes.versionString,
                "state": version.attributes.appStoreState ?? "unknown"
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

        if let ageRating = asc.ageRatingDeclaration {
            let attrs = ageRating.attributes
            var ageRatingDict: [String: Any] = ["id": ageRating.id]
            ageRatingDict["gambling"] = attrs.gambling ?? false
            ageRatingDict["messagingAndChat"] = attrs.messagingAndChat ?? false
            ageRatingDict["unrestrictedWebAccess"] = attrs.unrestrictedWebAccess ?? false
            ageRatingDict["userGeneratedContent"] = attrs.userGeneratedContent ?? false
            ageRatingDict["advertising"] = attrs.advertising ?? false
            ageRatingDict["lootBox"] = attrs.lootBox ?? false
            ageRatingDict["healthOrWellnessTopics"] = attrs.healthOrWellnessTopics ?? false
            ageRatingDict["parentalControls"] = attrs.parentalControls ?? false
            ageRatingDict["ageAssurance"] = attrs.ageAssurance ?? false
            ageRatingDict["alcoholTobaccoOrDrugUseOrReferences"] = attrs.alcoholTobaccoOrDrugUseOrReferences ?? "NONE"
            ageRatingDict["contests"] = attrs.contests ?? "NONE"
            ageRatingDict["gamblingSimulated"] = attrs.gamblingSimulated ?? "NONE"
            ageRatingDict["gunsOrOtherWeapons"] = attrs.gunsOrOtherWeapons ?? "NONE"
            ageRatingDict["horrorOrFearThemes"] = attrs.horrorOrFearThemes ?? "NONE"
            ageRatingDict["matureOrSuggestiveThemes"] = attrs.matureOrSuggestiveThemes ?? "NONE"
            ageRatingDict["medicalOrTreatmentInformation"] = attrs.medicalOrTreatmentInformation ?? "NONE"
            ageRatingDict["profanityOrCrudeHumor"] = attrs.profanityOrCrudeHumor ?? "NONE"
            ageRatingDict["sexualContentGraphicAndNudity"] = attrs.sexualContentGraphicAndNudity ?? "NONE"
            ageRatingDict["sexualContentOrNudity"] = attrs.sexualContentOrNudity ?? "NONE"
            ageRatingDict["violenceCartoonOrFantasy"] = attrs.violenceCartoonOrFantasy ?? "NONE"
            ageRatingDict["violenceRealistic"] = attrs.violenceRealistic ?? "NONE"
            ageRatingDict["violenceRealisticProlongedGraphicOrSadistic"] = attrs.violenceRealisticProlongedGraphicOrSadistic ?? "NONE"
            result["ageRating"] = ageRatingDict
        }

        if let reviewDetail = asc.reviewDetail {
            let attrs = reviewDetail.attributes
            result["reviewContact"] = [
                "contactFirstName": attrs.contactFirstName ?? "",
                "contactLastName": attrs.contactLastName ?? "",
                "contactEmail": attrs.contactEmail ?? "",
                "contactPhone": attrs.contactPhone ?? "",
                "notes": attrs.notes ?? "",
                "demoAccountRequired": attrs.demoAccountRequired ?? false,
                "demoAccountName": attrs.demoAccountName ?? "",
                "demoAccountPassword": attrs.demoAccountPassword ?? ""
            ]
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
        var result: [String: Any] = [
            "selectedLocale": selectedLocale,
            "availableLocales": asc.localizations.map(\.attributes.locale),
            "screenshotSets": sets,
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

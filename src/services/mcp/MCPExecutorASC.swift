import AppKit
import Foundation

extension MCPExecutor {
    // MARK: - ASC Form Tools

    private static let appInformationDetailFieldWriteOrder = [
        "copyright",
        "primaryCategory",
        "contentRightsDeclaration",
    ]

    private static let appInformationLocalizationFields: Set<String> = [
        "title", "name", "subtitle", "description", "keywords", "promotionalText",
        "marketingUrl", "supportUrl", "whatsNew", "privacyPolicyUrl",
    ]

    static let validFieldsByTab: [String: Set<String>] = [
        MCPAppInformationCompatibility.canonicalTab: appInformationLocalizationFields
            .union(appInformationDetailFieldWriteOrder),
        "monetization": ["isFree"],
        "review.ageRating": ["gambling", "messagingAndChat", "unrestrictedWebAccess",
                             "userGeneratedContent", "advertising", "lootBox",
                             "healthOrWellnessTopics", "parentalControls", "ageAssurance",
                             "alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated",
                             "gunsOrOtherWeapons", "horrorOrFearThemes", "matureOrSuggestiveThemes",
                             "medicalOrTreatmentInformation", "profanityOrCrudeHumor",
                             "sexualContentGraphicAndNudity", "sexualContentOrNudity",
                             "violenceCartoonOrFantasy", "violenceRealistic",
                             "violenceRealisticProlongedGraphicOrSadistic"],
        "review.contact": ["contactFirstName", "contactLastName", "contactEmail", "contactPhone",
                           "notes", "demoAccountRequired", "demoAccountName", "demoAccountPassword"],
        "settings.bundleId": ["bundleId"],
    ]

    static let fieldAliases: [String: String] = [
        "firstName": "contactFirstName",
        "lastName": "contactLastName",
        "email": "contactEmail",
        "phone": "contactPhone",
    ]

    static let reviewContactRequiredFieldKeys = [
        "contactFirstName",
        "contactLastName",
        "contactEmail",
        "contactPhone",
    ]

    static func normalizedReviewContactDraft(_ fields: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        for (field, value) in fields {
            if field == "contactPhone" {
                let stripped = value.hasPrefix("+")
                    ? "+" + value.dropFirst().filter(\.isNumber)
                    : value.filter(\.isNumber)
                normalized[field] = stripped
            } else if field == "demoAccountRequired" {
                normalized[field] = value == "true" ? "true" : "false"
            } else {
                normalized[field] = value
            }
        }
        return normalized
    }

    static func reviewContactStringValue(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func missingRequiredReviewContactFields(from attributes: [String: Any]) -> [String] {
        var missing = reviewContactRequiredFieldKeys.filter {
            reviewContactStringValue(attributes[$0]) == nil
        }

        let demoRequired = attributes["demoAccountRequired"] as? Bool == true
        if demoRequired {
            if reviewContactStringValue(attributes["demoAccountName"]) == nil {
                missing.append("demoAccountName")
            }
            if reviewContactStringValue(attributes["demoAccountPassword"]) == nil {
                missing.append("demoAccountPassword")
            }
        }

        return missing
    }

    static func mergedReviewContactAttributes(
        reviewDetail: ASCReviewDetail?,
        draft: [String: String]
    ) -> [String: Any] {
        var attributes: [String: Any] = [:]

        if let existing = reviewDetail?.attributes {
            if let contactFirstName = existing.contactFirstName, !contactFirstName.isEmpty {
                attributes["contactFirstName"] = contactFirstName
            }
            if let contactLastName = existing.contactLastName, !contactLastName.isEmpty {
                attributes["contactLastName"] = contactLastName
            }
            if let contactPhone = existing.contactPhone, !contactPhone.isEmpty {
                attributes["contactPhone"] = contactPhone
            }
            if let contactEmail = existing.contactEmail, !contactEmail.isEmpty {
                attributes["contactEmail"] = contactEmail
            }
            if let demoAccountRequired = existing.demoAccountRequired {
                attributes["demoAccountRequired"] = demoAccountRequired
            }
            if let demoAccountName = existing.demoAccountName, !demoAccountName.isEmpty {
                attributes["demoAccountName"] = demoAccountName
            }
            if let demoAccountPassword = existing.demoAccountPassword, !demoAccountPassword.isEmpty {
                attributes["demoAccountPassword"] = demoAccountPassword
            }
            if let notes = existing.notes, !notes.isEmpty {
                attributes["notes"] = notes
            }
        }

        for (field, value) in draft {
            if field == "demoAccountRequired" {
                attributes[field] = value == "true"
            } else {
                attributes[field] = value
            }
        }

        return attributes
    }

    static func missingRequiredReviewContactFieldsForInitialCreate(
        reviewDetail: ASCReviewDetail?,
        mergedAttributes: [String: Any]
    ) -> [String] {
        guard reviewDetail?.isPlaceholder != false else { return [] }
        return missingRequiredReviewContactFields(from: mergedAttributes)
    }

    @MainActor
    static func screenshotSaveDisplayTypes(
        requestedDisplayType: String?,
        locale: String,
        projectDisplayTypes: [String],
        asc: ASCManager
    ) -> [String] {
        if let requestedDisplayType {
            let trimmed = requestedDisplayType.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return [trimmed]
            }
        }

        let knownDisplayTypes = asc.orderedKnownScreenshotDisplayTypes(
            for: locale,
            preferredOrder: projectDisplayTypes
        )
        let candidateDisplayTypes = knownDisplayTypes.isEmpty ? projectDisplayTypes : knownDisplayTypes
        let stagedDisplayTypes = candidateDisplayTypes.filter {
            asc.hasTrackState(displayType: $0, locale: locale)
                || asc.hasUnsavedChanges(displayType: $0, locale: locale)
        }
        return stagedDisplayTypes.isEmpty ? candidateDisplayTypes : stagedDisplayTypes
    }

    private func screenshotsDisplayTypesForActiveProject() async -> [String] {
        await MainActor.run {
            switch appState.activeProject?.platform ?? .iOS {
            case .iOS:
                return ["APP_IPHONE_67", "APP_IPAD_PRO_3GEN_129"]
            case .macOS:
                return ["APP_DESKTOP"]
            }
        }
    }

    private func resolveAppInformationLocale(from args: [String: Any]) async -> String {
        if let requestedLocale = (args["locale"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !requestedLocale.isEmpty {
            return requestedLocale
        }

        return await MainActor.run {
            appState.ascManager.activeAppInformationLocale() ?? "en-US"
        }
    }

    private func prepareAppInformationLocale(
        _ locale: String,
        forceRefresh: Bool = false
    ) async -> String? {
        let trimmedLocale = locale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLocale.isEmpty else {
            return "Error: locale is required."
        }

        let needsRefresh = await MainActor.run { () -> Bool in
            let asc = appState.ascManager
            asc.selectedAppInformationLocale = trimmedLocale
            return forceRefresh
                || asc.localizations.isEmpty
                || !asc.localizations.contains(where: { $0.attributes.locale == trimmedLocale })
                || asc.appInfoLocalizationsByLocale.isEmpty
        }

        if needsRefresh {
            await appState.ascManager.refreshTabData(.appInformation)
        }

        let availableLocales = await MainActor.run {
            appState.ascManager.localizations.map(\.attributes.locale).sorted()
        }
        guard availableLocales.contains(trimmedLocale) else {
            let availableText = availableLocales.isEmpty ? "none" : availableLocales.joined(separator: ", ")
            return "Error: app information localization '\(trimmedLocale)' was not found after refreshing from ASC. "
                + "Available localizations: \(availableText)"
        }

        await MainActor.run {
            appState.ascManager.selectedAppInformationLocale = trimmedLocale
        }
        return nil
    }

    private func resolveScreenshotsLocale(from args: [String: Any]) async -> (locale: String, explicitlyRequested: Bool) {
        if let requestedLocale = (args["locale"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !requestedLocale.isEmpty {
            return (requestedLocale, true)
        }

        let locale = await MainActor.run {
            appState.ascManager.selectedScreenshotsLocale
                ?? appState.ascManager.localizations.first?.attributes.locale
                ?? "en-US"
        }
        return (locale, false)
    }

    private func activeVersionScopedTabForRefresh() async -> AppTab {
        await MainActor.run {
            switch appState.activeTab {
            case .appInformation, .screenshots, .review:
                return appState.activeTab
            default:
                return .app
            }
        }
    }

    private func versionPayload(_ version: ASCAppStoreVersion) -> [String: Any] {
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

    func executeASCSetCredentials(_ args: [String: Any]) async -> [String: Any] {
        guard let issuerId = args["issuerId"] as? String,
              let keyId = args["keyId"] as? String,
              let rawPath = args["privateKeyPath"] as? String else {
            return mcpText("Error: issuerId, keyId, and privateKeyPath are required.")
        }

        let path = NSString(string: rawPath).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path),
              let privateKey = try? String(contentsOfFile: path, encoding: .utf8),
              !privateKey.isEmpty else {
            return mcpText("Error: could not read private key file at \(rawPath)")
        }

        await MainActor.run {
            appState.ascManager.pendingCredentialValues = [
                "issuerId": issuerId,
                "keyId": keyId,
                "privateKey": privateKey,
                "privateKeyFileName": URL(fileURLWithPath: path).lastPathComponent
            ]
        }
        return mcpText("Credentials pre-filled. The user can verify and click 'Save Credentials'.")
    }

    func executeASCFillForm(_ args: [String: Any]) async throws -> [String: Any] {
        guard let rawTab = args["tab"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }
        let tab = MCPAppInformationCompatibility.canonicalTabName(rawTab)

        let fieldMap = parseFieldMap(args["fields"], applyAliases: true)
        guard !fieldMap.isEmpty else {
            throw MCPServerService.MCPError.invalidToolArgs
        }

        var resolvedAppInformationLocale: String?

        if let validFields = Self.validFieldsByTab[tab] {
            let invalid = fieldMap.keys.filter { !validFields.contains($0) }
            if !invalid.isEmpty {
                var hints: [String] = []
                for field in invalid {
                    for (otherTab, otherFields) in Self.validFieldsByTab where otherTab != tab {
                        if otherFields.contains(field) {
                            hints.append("'\(field)' belongs on tab '\(otherTab)'")
                        }
                    }
                }
                let hintStr = hints.isEmpty ? "" : " Hint: \(hints.joined(separator: "; "))."
                return mcpText(
                    "Error: invalid field(s) for tab '\(tab)': \(invalid.sorted().joined(separator: ", ")). "
                        + "Valid fields: \(validFields.sorted().joined(separator: ", ")).\(hintStr)"
                )
            }
        }

        var extraResponse: [String: Any] = [:]

        switch tab {
        case MCPAppInformationCompatibility.canonicalTab:
            let appInfoLocFields: Set<String> = ["name", "title", "subtitle", "privacyPolicyUrl"]
            var versionLocFields: [String: String] = [:]
            var infoLocFields: [String: String] = [:]
            var detailFields: [String: String] = [:]
            let hasLocalizedFields = fieldMap.keys.contains { Self.appInformationLocalizationFields.contains($0) }

            if hasLocalizedFields {
                let locale = await resolveAppInformationLocale(from: args)
                resolvedAppInformationLocale = locale

                if let localeError = await prepareAppInformationLocale(locale) {
                    _ = await MainActor.run { appState.ascManager.pendingFormValues.removeValue(forKey: tab) }
                    return mcpText(localeError)
                }
            }

            for (field, value) in fieldMap {
                if appInfoLocFields.contains(field) {
                    infoLocFields[field] = value
                } else if Self.appInformationDetailFieldWriteOrder.contains(field) {
                    detailFields[field] = value
                } else {
                    versionLocFields[field] = value
                }
            }

            if hasLocalizedFields, let locale = resolvedAppInformationLocale {
                await appState.ascManager.updateAppInformationFields(
                    versionFields: versionLocFields,
                    appInfoFields: infoLocFields,
                    locale: locale
                )
                if let err = await checkASCWriteError(tab: tab) { return err }
            }

            for field in Self.appInformationDetailFieldWriteOrder {
                guard let value = detailFields[field] else { continue }
                await appState.ascManager.updateAppInfoField(field, value: value)
                if let err = await checkASCWriteError(tab: tab) { return err }
            }

        case "monetization":
            guard let isFree = fieldMap["isFree"] else {
                return mcpText(
                    "Error: monetization tab requires the 'isFree' field (value: \"true\" or \"false\")."
                )
            }
            if isFree == "true" {
                await appState.ascManager.setPriceFree()
            } else {
                return mcpText(
                    "To set a paid price, use the asc_set_app_price tool with a price parameter (e.g. price=\"0.99\")."
                )
            }
            if let err = await checkASCWriteError(tab: tab) { return err }

        case "review.ageRating":
            var attrs: [String: Any] = [:]
            let boolFields = Set(["gambling", "messagingAndChat", "unrestrictedWebAccess",
                                  "userGeneratedContent", "advertising", "lootBox",
                                  "healthOrWellnessTopics", "parentalControls", "ageAssurance"])
            for (field, value) in fieldMap {
                attrs[field] = boolFields.contains(field) ? (value == "true") : value
            }
            await appState.ascManager.updateAgeRating(attrs)
            if let err = await checkASCWriteError(tab: tab) { return err }

        case "review.contact":
            let normalizedDraft = await MainActor.run { () -> [String: String] in
                let merged = (appState.ascManager.pendingFormValues[tab] ?? [:]).merging(fieldMap) { _, new in new }
                let normalized = Self.normalizedReviewContactDraft(merged)
                return normalized
            }

            let mergedAttributes = await MainActor.run {
                Self.mergedReviewContactAttributes(
                    reviewDetail: appState.ascManager.reviewDetail,
                    draft: normalizedDraft
                )
            }

            let missingInitialCreateFields = await MainActor.run {
                Self.missingRequiredReviewContactFieldsForInitialCreate(
                    reviewDetail: appState.ascManager.reviewDetail,
                    mergedAttributes: mergedAttributes
                )
            }
            if !missingInitialCreateFields.isEmpty {
                await MainActor.run {
                    if appState.ascManager.pendingFormValues.removeValue(forKey: tab) != nil {
                        appState.ascManager.pendingFormVersion += 1
                    }
                    appState.ascManager.writeError = nil
                }
                return mcpText(
                    "Error: App Store Connect requires \(missingInitialCreateFields.joined(separator: ", ")) "
                        + "to create the initial review contact resource. Re-send the full required contact block together."
                )
            }

            await appState.ascManager.updateReviewContact(mergedAttributes)

            let reviewContactWriteError = await MainActor.run { () -> String? in
                let asc = appState.ascManager
                let error = asc.writeError
                asc.writeError = nil

                if error == nil {
                    if asc.pendingFormValues.removeValue(forKey: tab) != nil {
                        asc.pendingFormVersion += 1
                    }
                }

                return error
            }
            if let reviewContactWriteError {
                return mcpText("Error: \(reviewContactWriteError)")
            }

            let persistedMissingRequired = await MainActor.run {
                Self.missingRequiredReviewContactFields(
                    from: Self.mergedReviewContactAttributes(
                        reviewDetail: appState.ascManager.reviewDetail,
                        draft: [:]
                    )
                )
            }
            extraResponse["saved"] = true
            extraResponse["pending"] = false
            extraResponse["missingRequired"] = persistedMissingRequired
            if persistedMissingRequired.isEmpty {
                extraResponse["message"] = "Review contact was saved to ASC."
            } else {
                extraResponse["message"] =
                    "Review contact was saved to ASC. Required fields still missing in App Store Connect: \(persistedMissingRequired.joined(separator: ", "))."
            }

        case "settings.bundleId":
            if let bundleId = fieldMap["bundleId"] {
                let projectPath = await MainActor.run { appState.activeProject?.path }
                await MainActor.run {
                    guard let projectId = appState.activeProjectId else { return }
                    let storage = ProjectStorage()
                    guard var metadata = storage.readMetadata(projectId: projectId) else { return }
                    metadata.bundleIdentifier = bundleId
                    try? storage.writeMetadata(projectId: projectId, metadata: metadata)
                }
                if let projectPath {
                    let pipeline = BuildPipelineService()
                    await pipeline.updateBundleIdInPbxproj(projectPath: projectPath, bundleId: bundleId)
                }
                await appState.projectManager.loadProjects()
                let hasCreds = await MainActor.run { appState.ascManager.credentials != nil }
                if hasCreds {
                    await appState.ascManager.fetchApp(bundleId: bundleId)
                }
            }

        default:
            return mcpText("Unknown tab: \(tab)")
        }

        _ = await MainActor.run { appState.ascManager.pendingFormValues.removeValue(forKey: tab) }
        var response: [String: Any] = ["success": true, "tab": tab, "fieldsUpdated": fieldMap.count]
        if let resolvedAppInformationLocale {
            response["locale"] = resolvedAppInformationLocale
        }
        for (key, value) in extraResponse {
            response[key] = value
        }
        return mcpJSON(response)
    }

    func executeAppInformationSwitchLocalization(_ args: [String: Any]) async throws -> [String: Any] {
        guard let rawLocale = args["locale"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }

        let locale = rawLocale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !locale.isEmpty else {
            throw MCPServerService.MCPError.invalidToolArgs
        }

        if let localeError = await prepareAppInformationLocale(locale, forceRefresh: true) {
            return mcpText(localeError)
        }

        let state = await MainActor.run { () -> [String: Any] in
            let asc = appState.ascManager
            let versionLocalization = asc.appInformationLocalization(locale: locale)
            let appInfoLocalization = asc.appInfoLocalizationForLocale(locale)
            let fields: [String: String] = [
                "name": appInfoLocalization?.attributes.name ?? versionLocalization?.attributes.title ?? "",
                "subtitle": appInfoLocalization?.attributes.subtitle ?? versionLocalization?.attributes.subtitle ?? "",
                "description": versionLocalization?.attributes.description ?? "",
                "keywords": versionLocalization?.attributes.keywords ?? "",
                "promotionalText": versionLocalization?.attributes.promotionalText ?? "",
                "marketingUrl": versionLocalization?.attributes.marketingUrl ?? "",
                "supportUrl": versionLocalization?.attributes.supportUrl ?? "",
                "whatsNew": versionLocalization?.attributes.whatsNew ?? "",
                "privacyPolicyUrl": appInfoLocalization?.attributes.privacyPolicyUrl ?? ""
            ]
            var response: [String: Any] = [
                "success": true,
                "locale": locale,
                "availableLocales": asc.localizations.map(\.attributes.locale).sorted(),
                "hasAppInfoLocalization": appInfoLocalization != nil,
                "details": [
                    "copyright": asc.selectedVersion?.attributes.copyright ?? "",
                    "primaryCategory": asc.appInfo?.primaryCategoryId ?? "",
                    "contentRightsDeclaration": asc.app?.contentRightsDeclaration ?? "",
                ],
            ]
            response["fields"] = fields
            return response
        }

        return mcpJSON(state)
    }

    func executeASCSelectVersion(_ args: [String: Any]) async throws -> [String: Any] {
        guard let rawIdentifier = args["version"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }

        let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else {
            throw MCPServerService.MCPError.invalidToolArgs
        }

        await ASCUpdateLogger.shared.event("mcp_select_version_started", metadata: [
            "version": identifier,
        ])

        await appState.ascManager.ensureTabData(.app)

        var resolvedVersion = await MainActor.run {
            appState.ascManager.version(matching: identifier)
        }
        if resolvedVersion == nil {
            await appState.ascManager.refreshTabData(.app)
            resolvedVersion = await MainActor.run {
                appState.ascManager.version(matching: identifier)
            }
        }

        guard let resolvedVersion else {
            await ASCUpdateLogger.shared.event("mcp_select_version_failed", metadata: [
                "reason": "not_found",
                "version": identifier,
            ])
            return mcpText("Error: app version '\(identifier)' was not found.")
        }

        // Refresh only the currently relevant version-scoped tab so the UI and
        // tab-state payloads stay aligned with the new version selection.
        let refreshTab = await activeVersionScopedTabForRefresh()
        await MainActor.run {
            appState.ascManager.prepareForVersionSelection(resolvedVersion.id)
        }
        await appState.ascManager.refreshTabData(refreshTab)

        await ASCUpdateLogger.shared.event("mcp_select_version_succeeded", metadata: [
            "refreshedTab": refreshTab.rawValue,
            "versionId": resolvedVersion.id,
            "versionString": resolvedVersion.attributes.versionString,
        ])

        return mcpJSON([
            "success": true,
            "refreshedTab": refreshTab.rawValue,
            "selectedVersion": versionPayload(resolvedVersion),
        ])
    }

    func executeASCCreateVersion(_ args: [String: Any]) async throws -> [String: Any] {
        guard let rawVersionString = args["versionString"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }

        let versionString = rawVersionString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !versionString.isEmpty else {
            throw MCPServerService.MCPError.invalidToolArgs
        }

        let copyFromVersion = (args["copyFromVersion"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let attachBuildId = (args["attachBuildId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let copyMetadata = args["copyMetadata"] as? Bool ?? true
        let copyReviewDetail = args["copyReviewDetail"] as? Bool ?? true
        let platform = await MainActor.run { appState.activeProject?.platform ?? .iOS }

        await ASCUpdateLogger.shared.event("mcp_create_version_started", metadata: [
            "attachBuildId": attachBuildId ?? "nil",
            "copyFromVersion": copyFromVersion ?? "nil",
            "copyMetadata": copyMetadata ? "true" : "false",
            "copyReviewDetail": copyReviewDetail ? "true" : "false",
            "versionString": versionString,
        ])

        await appState.ascManager.createUpdateVersion(
            versionString: versionString,
            platform: platform,
            copyFromVersionId: copyFromVersion?.isEmpty == false ? copyFromVersion : nil,
            copyMetadata: copyMetadata,
            copyReviewDetail: copyReviewDetail,
            attachBuildId: attachBuildId?.isEmpty == false ? attachBuildId : nil
        )

        if let error = await MainActor.run(body: { appState.ascManager.versionCreationError }) {
            await ASCUpdateLogger.shared.event("mcp_create_version_failed", metadata: [
                "error": error,
                "versionString": versionString,
            ])
            return mcpText("Error: \(error)")
        }

        guard let createdVersion = await MainActor.run(body: {
            appState.ascManager.version(matching: versionString)
        }) else {
            await ASCUpdateLogger.shared.event("mcp_create_version_failed", metadata: [
                "reason": "version_missing_after_create",
                "versionString": versionString,
            ])
            return mcpText("Error: version creation did not complete.")
        }

        let canCreateUpdate = await MainActor.run(body: { appState.ascManager.canCreateUpdate })
        await ASCUpdateLogger.shared.event("mcp_create_version_succeeded", metadata: [
            "versionId": createdVersion.id,
            "versionString": createdVersion.attributes.versionString,
        ])

        return mcpJSON([
            "success": true,
            "selectedVersion": versionPayload(createdVersion),
            "canCreateUpdate": canCreateUpdate,
        ])
    }

    func executeScreenshotsAddAsset(_ args: [String: Any]) async throws -> [String: Any] {
        guard let sourcePath = args["sourcePath"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }
        let expanded = (sourcePath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            return mcpText("Error: file not found at \(expanded)")
        }

        guard let projectId = await MainActor.run(body: { appState.activeProjectId }) else {
            return mcpText("Error: no active project")
        }

        let destDir = BlitzPaths.screenshots(projectId: projectId)
        let fm = FileManager.default
        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        let fileName = args["fileName"] as? String ?? (expanded as NSString).lastPathComponent
        let dest = destDir.appendingPathComponent(fileName)

        do {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(atPath: expanded, toPath: dest.path)
        } catch {
            return mcpText("Error copying file: \(error.localizedDescription)")
        }

        await MainActor.run { appState.ascManager.scanLocalAssets(projectId: projectId) }
        return mcpJSON(["success": true, "fileName": fileName])
    }

    func executeScreenshotsSwitchLocalization(_ args: [String: Any]) async throws -> [String: Any] {
        guard let rawLocale = args["locale"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }
        let locale = rawLocale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !locale.isEmpty else {
            throw MCPServerService.MCPError.invalidToolArgs
        }

        let previousLocale = await MainActor.run {
            let previous = appState.ascManager.selectedScreenshotsLocale
            appState.ascManager.selectedScreenshotsLocale = locale
            return previous
        }

        await appState.ascManager.refreshTabData(.screenshots)

        let availableLocales = await MainActor.run {
            appState.ascManager.localizations.map(\.attributes.locale).sorted()
        }
        guard availableLocales.contains(locale) else {
            await MainActor.run {
                appState.ascManager.selectedScreenshotsLocale = previousLocale
            }
            let availableText = availableLocales.isEmpty ? "none" : availableLocales.joined(separator: ", ")
            return mcpText(
                "Error: screenshot localization '\(locale)' was not found after refreshing from ASC. "
                    + "Available localizations: \(availableText)"
            )
        }

        await appState.ascManager.loadScreenshots(locale: locale, force: true)

        let displayTypes = await screenshotsDisplayTypesForActiveProject()
        let trackCounts = await MainActor.run { () -> [String: Int] in
            var counts: [String: Int] = [:]
            for displayType in displayTypes {
                appState.ascManager.loadTrackFromASC(displayType: displayType, locale: locale)
                counts[displayType] = appState.ascManager
                    .trackSlotsForDisplayType(displayType, locale: locale)
                    .compactMap { $0 }
                    .count
            }
            return counts
        }

        return mcpJSON([
            "success": true,
            "locale": locale,
            "availableLocales": availableLocales,
            "trackCounts": trackCounts
        ])
    }

    func executeScreenshotsSetTrack(_ args: [String: Any]) async throws -> [String: Any] {
        guard let assetFileName = args["assetFileName"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }
        guard let slotRaw = args["slotIndex"] as? Int ?? (args["slotIndex"] as? Double).map({ Int($0) }),
              slotRaw >= 1 && slotRaw <= 10 else {
            return mcpText("Error: slotIndex must be between 1 and 10")
        }
        let slotIndex = slotRaw - 1
        let displayType = args["displayType"] as? String ?? "APP_IPHONE_67"
        let (locale, explicitlyRequestedLocale) = await resolveScreenshotsLocale(from: args)

        let selectedLocale = await MainActor.run {
            appState.ascManager.selectedScreenshotsLocale ?? appState.ascManager.localizations.first?.attributes.locale
        }
        if explicitlyRequestedLocale, selectedLocale != locale {
            return mcpText(
                "Error: screenshots locale '\(locale)' is not selected in Blitz. "
                    + "Call screenshots_switch_localization first."
            )
        }

        guard let projectId = await MainActor.run(body: { appState.activeProjectId }) else {
            return mcpText("Error: no active project")
        }

        let dir = BlitzPaths.screenshots(projectId: projectId)
        let filePath = dir.appendingPathComponent(assetFileName).path

        guard FileManager.default.fileExists(atPath: filePath) else {
            return mcpText("Error: asset '\(assetFileName)' not found in local screenshots library")
        }

        await MainActor.run {
            let asc = appState.ascManager
            if !asc.hasTrackState(displayType: displayType, locale: locale),
               selectedLocale == locale {
                asc.loadTrackFromASC(displayType: displayType, locale: locale)
            }
        }
        let trackReady = await MainActor.run {
            appState.ascManager.hasTrackState(displayType: displayType, locale: locale)
        }
        guard trackReady else {
            return mcpText(
                "Error: screenshot locale '\(locale)' is not prepared in Blitz. "
                    + "Call screenshots_switch_localization first."
            )
        }

        let error = await MainActor.run {
            appState.ascManager.addAssetToTrack(
                displayType: displayType,
                slotIndex: slotIndex,
                localPath: filePath,
                locale: locale
            )
        }
        if let error {
            return mcpText("Error: \(error)")
        }
        return mcpJSON(["success": true, "slot": slotRaw, "locale": locale])
    }

    func executeScreenshotsSave(_ args: [String: Any]) async throws -> [String: Any] {
        let requestedDisplayType = args["displayType"] as? String
        let (locale, explicitlyRequestedLocale) = await resolveScreenshotsLocale(from: args)
        let projectDisplayTypes = await screenshotsDisplayTypesForActiveProject()

        let selectedLocale = await MainActor.run {
            appState.ascManager.selectedScreenshotsLocale ?? appState.ascManager.localizations.first?.attributes.locale
        }
        if explicitlyRequestedLocale, selectedLocale != locale {
            return mcpText(
                "Error: screenshots locale '\(locale)' is not selected in Blitz. "
                    + "Call screenshots_switch_localization first."
            )
        }

        let displayTypes = await MainActor.run {
            Self.screenshotSaveDisplayTypes(
                requestedDisplayType: requestedDisplayType,
                locale: locale,
                projectDisplayTypes: projectDisplayTypes,
                asc: appState.ascManager
            )
        }

        var syncedTracks: [[String: Any]] = []
        var hadChanges = false
        var preparedTrackCount = 0

        for displayType in displayTypes {
            await MainActor.run {
                let asc = appState.ascManager
                if !asc.hasTrackState(displayType: displayType, locale: locale),
                   selectedLocale == locale {
                    asc.loadTrackFromASC(displayType: displayType, locale: locale)
                }
            }

            let trackReady = await MainActor.run {
                appState.ascManager.hasTrackState(displayType: displayType, locale: locale)
            }
            if !trackReady {
                if requestedDisplayType != nil {
                    return mcpText(
                        "Error: screenshot locale '\(locale)' is not prepared in Blitz. "
                            + "Call screenshots_switch_localization first."
                    )
                }
                continue
            }
            preparedTrackCount += 1

            let trackHasChanges = await MainActor.run {
                appState.ascManager.hasUnsavedChanges(displayType: displayType, locale: locale)
            }
            if !trackHasChanges {
                continue
            }

            hadChanges = true
            await appState.ascManager.syncTrackToASC(displayType: displayType, locale: locale)

            if let err = await checkASCWriteError(tab: "screenshots") { return err }

            let slotCount = await MainActor.run {
                appState.ascManager.trackSlotsForDisplayType(displayType, locale: locale).compactMap { $0 }.count
            }
            syncedTracks.append([
                "displayType": displayType,
                "synced": slotCount,
            ])
        }

        guard preparedTrackCount > 0 else {
            return mcpText(
                "Error: screenshot locale '\(locale)' is not prepared in Blitz. "
                    + "Call screenshots_switch_localization first."
            )
        }

        guard hadChanges else {
            return mcpJSON([
                "success": true,
                "message": "No changes to save",
                "locale": locale,
                "displayTypes": displayTypes,
            ])
        }

        let totalSynced = syncedTracks.reduce(0) { partialResult, entry in
            partialResult + (entry["synced"] as? Int ?? 0)
        }
        return mcpJSON([
            "success": true,
            "synced": totalSynced,
            "locale": locale,
            "tracks": syncedTracks,
        ])
    }

    func executeASCOpenSubmitPreview() async -> [String: Any] {
        let needsVersionCreation = await MainActor.run {
            let asc = appState.ascManager
            return asc.canCreateUpdate || (asc.currentUpdateVersion == nil && asc.editableVersion == nil)
        }
        if needsVersionCreation {
            await ASCUpdateLogger.shared.event("mcp_open_submit_preview_blocked", metadata: [
                "reason": "missing_app_store_version",
            ])
            return mcpJSON([
                "ready": false,
                "missing": ["App Store Version"],
                "canCreateUpdate": true,
            ])
        }

        await appState.ascManager.syncOverviewSubmissionReadiness(forceRefresh: true)

        var readiness = await MainActor.run { appState.ascManager.submissionReadiness }
        let hasLockedUpdateOnly = await MainActor.run {
            let asc = appState.ascManager
            return asc.editableVersion == nil && asc.currentUpdateVersion != nil
        }
        if hasLockedUpdateOnly {
            await MainActor.run {
                appState.ascManager.showSubmitPreview = true
            }
            await ASCUpdateLogger.shared.event("mcp_open_submit_preview_status_only", metadata: [:])
            return mcpJSON(["ready": true, "opened": true, "statusOnly": true])
        }

        let buildMissing = readiness.missingRequired.contains { $0.label == "Build" }
        if buildMissing {
            let service = await MainActor.run { appState.ascManager.service }
            let appId = await MainActor.run { appState.ascManager.app?.id }
            if let service, let appId,
               let latestBuild = try? await service.fetchLatestBuild(appId: appId),
               latestBuild.attributes.processingState == "VALID" {
                let versionId = await MainActor.run { () -> String? in
                    let asc = appState.ascManager
                    if let selectedVersion = asc.selectedVersion,
                       ASCReleaseStatus.isEditable(selectedVersion.attributes.appStoreState) {
                        return selectedVersion.id
                    }
                    return asc.editableVersion?.id
                }
                if let versionId {
                    do {
                        try await service.attachBuild(versionId: versionId, buildId: latestBuild.id)
                        await MainActor.run {
                            if appState.ascManager.selectedVersion?.id == versionId {
                                appState.ascManager.selectedVersionBuild = latestBuild
                            }
                        }
                        await appState.ascManager.syncOverviewSubmissionReadiness(forceRefresh: true)
                        readiness = await MainActor.run { appState.ascManager.submissionReadiness }
                        await ASCUpdateLogger.shared.event("mcp_open_submit_preview_auto_attached_build", metadata: [
                            "buildId": latestBuild.id,
                            "versionId": versionId,
                        ])
                    } catch {
                        // Non-fatal: readiness will still surface the missing build.
                        await ASCUpdateLogger.shared.event("mcp_open_submit_preview_auto_attach_failed", metadata: [
                            "buildId": latestBuild.id,
                            "error": error.localizedDescription,
                            "versionId": versionId,
                        ])
                    }
                }
            }
        }

        if !readiness.isComplete {
            let missing = readiness.missingRequired.map { $0.label }
            await ASCUpdateLogger.shared.event("mcp_open_submit_preview_incomplete", metadata: [
                "missing": missing.joined(separator: ","),
            ])
            return mcpJSON(["ready": false, "missing": missing])
        }

        await MainActor.run {
            appState.ascManager.showSubmitPreview = true
        }
        await ASCUpdateLogger.shared.event("mcp_open_submit_preview_opened", metadata: [:])

        return mcpJSON(["ready": true, "opened": true])
    }

    // MARK: - ASC IAP / Subscriptions / Pricing Tools

    static func priceMatches(_ customerPrice: String?, target: String) -> Bool {
        guard let customerPrice else { return false }
        guard let a = Double(customerPrice), let b = Double(target) else {
            return customerPrice == target
        }
        return abs(a - b) < 0.001
    }

    func executeASCWebAuth() async -> [String: Any] {
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
        }

        guard let session = await appState.ascManager.requestWebAuthForMCP() else {
            let authError = await MainActor.run { appState.ascManager.irisFeedbackError }
            if let authError, !authError.isEmpty {
                return mcpJSON([
                    "success": false,
                    "cancelled": false,
                    "message": authError
                ])
            }
            return mcpJSON([
                "success": false,
                "cancelled": true,
                "message": "Web authentication was cancelled before a session was captured."
            ])
        }

        let email = session.email ?? "unknown"
        return mcpJSON([
            "success": true,
            "email": email,
            "message": "Web session authenticated and synced to ~/.blitz/asc-agent/web-session.json. The asc-iap-attach skill can now use the iris API."
        ])
    }

    func executeASCSetAppPrice(_ args: [String: Any]) async throws -> [String: Any] {
        guard let priceStr = args["price"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }
        let effectiveDate = args["effectiveDate"] as? String

        guard let service = await MainActor.run(body: { appState.ascManager.service }) else {
            return mcpText("Error: ASC service not configured")
        }
        guard let appId = await MainActor.run(body: { appState.ascManager.app?.id }) else {
            return mcpText("Error: no ASC app loaded. Open a project with a bundle ID first.")
        }

        if let priceVal = Double(priceStr), priceVal < 0.001 {
            let startedAt = Date()
            do {
                try await service.setPriceFree(appId: appId)
                try await service.ensureAppAvailability(appId: appId)
                await MainActor.run {
                    appState.ascManager.currentAppPricePointId = appState.ascManager.freeAppPricePointId
                    appState.ascManager.scheduledAppPricePointId = nil
                    appState.ascManager.scheduledAppPriceEffectiveDate = nil
                    appState.ascManager.monetizationStatus = "Free"
                }
                await appState.ascManager.refreshTabData(.monetization)
                AnalyticsService.trackBlitzManagedASCUsage(
                    commandType: "app_price.free",
                    success: true,
                    startedAt: startedAt
                )
                return mcpJSON([
                    "success": true,
                    "price": "0.00",
                    "message": "App set to free with territory availability configured"
                ])
            } catch {
                AnalyticsService.trackBlitzManagedASCUsage(
                    commandType: "app_price.free",
                    success: false,
                    startedAt: startedAt
                )
                throw error
            }
        }

        let commandType = effectiveDate == nil ? "app_price.set" : "app_price.schedule"
        let startedAt = Date()

        do {
            let pricePoints = try await service.fetchAppPricePoints(appId: appId)
            guard let match = pricePoints.first(where: {
                Self.priceMatches($0.attributes.customerPrice, target: priceStr)
            }) else {
                let sorted = pricePoints.compactMap { $0.attributes.customerPrice }
                    .compactMap { Double($0) }
                    .filter { $0 > 0 }
                    .sorted()
                let samples = sorted.count <= 30 ? sorted : {
                    let lo = Array(sorted.prefix(5))
                    let hi = Array(sorted.suffix(5))
                    let step = max(1, (sorted.count - 10) / 10)
                    let mid = stride(from: 5, to: sorted.count - 5, by: step).map { sorted[$0] }
                    return lo + mid + hi
                }()
                let formatted = samples.map { String(format: "%.2f", $0) }
                return mcpText(
                    "Error: no price point matching $\(priceStr). \(sorted.count) tiers available, "
                        + "samples: \(formatted.joined(separator: ", "))"
                )
            }

            if let effectiveDate {
                let freePoint = pricePoints.first(where: {
                    let p = $0.attributes.customerPrice ?? "0"
                    return p == "0" || p == "0.0" || p == "0.00"
                })
                let currentId = freePoint?.id ?? match.id
                try await service.setScheduledAppPrice(
                    appId: appId,
                    currentPricePointId: currentId,
                    futurePricePointId: match.id,
                    effectiveDate: effectiveDate
                )
                try await service.ensureAppAvailability(appId: appId)
                await MainActor.run {
                    appState.ascManager.currentAppPricePointId = currentId
                    appState.ascManager.scheduledAppPricePointId = match.id
                    appState.ascManager.scheduledAppPriceEffectiveDate = effectiveDate
                    appState.ascManager.monetizationStatus = "Configured"
                }
                await appState.ascManager.refreshTabData(.monetization)
                AnalyticsService.trackBlitzManagedASCUsage(
                    commandType: commandType,
                    success: true,
                    startedAt: startedAt
                )
                return mcpJSON([
                    "success": true,
                    "price": priceStr,
                    "effectiveDate": effectiveDate,
                    "message": "Scheduled price change for \(effectiveDate) with territory availability configured"
                ])
            }

            try await service.setAppPrice(appId: appId, pricePointId: match.id)
            try await service.ensureAppAvailability(appId: appId)
            await MainActor.run {
                appState.ascManager.currentAppPricePointId = match.id
                appState.ascManager.scheduledAppPricePointId = nil
                appState.ascManager.scheduledAppPriceEffectiveDate = nil
                appState.ascManager.monetizationStatus = "Configured"
            }
            await appState.ascManager.refreshTabData(.monetization)
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: commandType,
                success: true,
                startedAt: startedAt
            )
            return mcpJSON(["success": true, "price": priceStr, "pricePointId": match.id])
        } catch {
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: commandType,
                success: false,
                startedAt: startedAt
            )
            throw error
        }
    }

    func executeASCCreateIAP(_ args: [String: Any]) async throws -> [String: Any] {
        guard let productId = args["productId"] as? String,
              let name = args["name"] as? String,
              let type = args["type"] as? String,
              let displayName = args["displayName"] as? String,
              let priceStr = args["price"] as? String,
              let screenshotPath = args["screenshotPath"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }
        let description = args["description"] as? String

        let validTypes = ["CONSUMABLE", "NON_CONSUMABLE", "NON_RENEWING_SUBSCRIPTION"]
        guard validTypes.contains(type) else {
            return mcpText("Error: invalid type '\(type)'. Must be one of: \(validTypes.joined(separator: ", "))")
        }

        await MainActor.run {
            var values: [String: String] = [
                "kind": "iap",
                "name": name,
                "productId": productId,
                "type": type,
                "displayName": displayName,
                "price": priceStr
            ]
            if let description { values["description"] = description }
            appState.ascManager.pendingCreateValues = values
        }

        await MainActor.run {
            appState.ascManager.createIAP(
                name: name,
                productId: productId,
                type: type,
                displayName: displayName,
                description: description,
                price: priceStr,
                screenshotPath: screenshotPath
            )
        }

        if let error = await pollASCCreation() {
            return mcpText("Error creating IAP: \(error)")
        }

        return mcpJSON([
            "success": true,
            "productId": productId,
            "type": type,
            "displayName": displayName,
            "price": priceStr
        ])
    }

    func executeASCCreateSubscription(_ args: [String: Any]) async throws -> [String: Any] {
        guard let groupName = args["groupName"] as? String,
              let productId = args["productId"] as? String,
              let name = args["name"] as? String,
              let displayName = args["displayName"] as? String,
              let duration = args["duration"] as? String,
              let priceStr = args["price"] as? String,
              let screenshotPath = args["screenshotPath"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }
        let description = args["description"] as? String

        let validDurations = ["ONE_WEEK", "ONE_MONTH", "TWO_MONTHS", "THREE_MONTHS", "SIX_MONTHS", "ONE_YEAR"]
        guard validDurations.contains(duration) else {
            return mcpText(
                "Error: invalid duration '\(duration)'. Must be one of: \(validDurations.joined(separator: ", "))"
            )
        }

        await MainActor.run {
            var values: [String: String] = [
                "kind": "subscription",
                "groupName": groupName,
                "name": name,
                "productId": productId,
                "displayName": displayName,
                "duration": duration,
                "price": priceStr
            ]
            if let description { values["description"] = description }
            appState.ascManager.pendingCreateValues = values
        }

        await MainActor.run {
            appState.ascManager.createSubscription(
                groupName: groupName,
                name: name,
                productId: productId,
                displayName: displayName,
                description: description,
                duration: duration,
                price: priceStr,
                screenshotPath: screenshotPath
            )
        }

        if let error = await pollASCCreation() {
            return mcpText("Error creating subscription: \(error)")
        }

        return mcpJSON([
            "success": true,
            "groupName": groupName,
            "productId": productId,
            "displayName": displayName,
            "duration": duration,
            "price": priceStr
        ])
    }

    func pollASCCreation() async -> String? {
        for _ in 0..<10 {
            let creating = await MainActor.run { appState.ascManager.isCreating }
            if creating { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        while await MainActor.run(body: { appState.ascManager.isCreating }) {
            try? await Task.sleep(for: .milliseconds(500))
        }
        return await MainActor.run { appState.ascManager.writeError }
    }

    func executeGetRejectionFeedback(_ args: [String: Any]) async throws -> [String: Any] {
        let raw = await MainActor.run { () -> [String: Any] in
            let asc = appState.ascManager
            guard let appId = asc.app?.id else {
                return ["error": "No app connected. Set up ASC credentials first."]
            }

            let requestedVersion = args["version"] as? String
            let version: String
            if let requestedVersion {
                version = requestedVersion
            } else if let rejected = asc.appStoreVersions.first(where: {
                let state = ($0.attributes.appStoreState ?? "").uppercased()
                return state == "REJECTED" || state == "METADATA_REJECTED"
            }) {
                version = rejected.attributes.versionString
            } else {
                return ["error": "No rejected version found.", "appId": appId]
            }

            asc.loadCachedFeedback(appId: appId, versionString: version)
            let cycles = asc.feedbackCycles(forVersionString: version)
            if !cycles.isEmpty {
                let payload = cycles.map { cycle -> [String: Any] in
                    let reasons = cycle.reasons.map { reason in
                        ["section": reason.section, "description": reason.description, "code": reason.code]
                    }
                    let messages = cycle.messages.map { message -> [String: String] in
                        var msg = ["body": message.body]
                        if let date = message.createdAt { msg["date"] = date }
                        return msg
                    }
                    return [
                        "id": cycle.id,
                        "version": cycle.versionString ?? version,
                        "submissionId": cycle.submissionId ?? "",
                        "occurredAt": cycle.occurredAt,
                        "source": cycle.source,
                        "reasons": reasons,
                        "messages": messages
                    ]
                }
                return [
                    "appId": appId,
                    "version": version,
                    "cycles": payload,
                    "source": "archive"
                ]
            }

            return [
                "error": "No rejection feedback cached for version \(version). The user needs to sign in with their Apple ID in the ASC Overview tab to fetch feedback.",
                "appId": appId,
                "version": version
            ]
        }
        return mcpJSON(raw)
    }
}

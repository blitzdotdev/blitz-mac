import Foundation

extension ASCManager {
    /// ASC returns an age rating declaration object with nil fields by default.
    /// Submitting with nil fields later causes a 409.
    var ageRatingIsConfigured: Bool {
        guard let attributes = ageRatingDeclaration?.attributes else { return false }
        return attributes.alcoholTobaccoOrDrugUseOrReferences != nil
            && attributes.violenceCartoonOrFantasy != nil
            && attributes.violenceRealistic != nil
            && attributes.sexualContentOrNudity != nil
            && attributes.sexualContentGraphicAndNudity != nil
            && attributes.profanityOrCrudeHumor != nil
            && attributes.gamblingSimulated != nil
    }

    private func whatsNewReadinessFields() -> [SubmissionReadiness.FieldStatus] {
        guard selectedVersionRequiresWhatsNew else { return [] }

        // Update versions require release notes for every loaded localization on
        // that version, not just the primary locale used elsewhere in Overview.
        if localizations.isEmpty {
            return [
                SubmissionReadiness.FieldStatus(
                    label: Self.overviewWhatsNewFieldLabel,
                    value: nil,
                    isLoading: overviewReadinessLoadingFields.contains(Self.overviewWhatsNewFieldLabel),
                    hint: "Fill What's New in Store Listing before submitting this update."
                )
            ]
        }

        let missingLocalizations = selectedVersionLocalizationsMissingWhatsNew()
        if missingLocalizations.isEmpty {
            return [
                SubmissionReadiness.FieldStatus(
                    label: Self.overviewWhatsNewFieldLabel,
                    value: "Configured for \(localizations.count) localization(s)",
                    hint: "App Store updates require What's New text for each localization on the selected version."
                )
            ]
        }

        return missingLocalizations.map { localization in
            SubmissionReadiness.FieldStatus(
                label: "\(Self.overviewWhatsNewFieldLabel) (\(localization.attributes.locale))",
                value: nil,
                hint: "Fill What's New for locale \(localization.attributes.locale) in Store Listing before submitting this update."
            )
        }
    }

    var submissionReadiness: SubmissionReadiness {
        let localization = primaryVersionLocalization()
        let appInfoLocalization = primaryAppInfoLocalization()
        let review = reviewDetail
        let demoRequired = review?.attributes.demoAccountRequired == true
        let version = selectedVersion
        let readinessLocale = localization?.attributes.locale
        let readinessScreenshotSets = readinessLocale.map(screenshotSetsForLocale) ?? []
        let readinessScreenshots = readinessLocale.map(screenshotsForLocale) ?? [:]

        let macScreenshots = readinessScreenshotSets.first { $0.attributes.screenshotDisplayType == "APP_DESKTOP" }
        let isMacApp = macScreenshots != nil
        let iphoneScreenshots = readinessScreenshotSets.first { $0.attributes.screenshotDisplayType == "APP_IPHONE_67" }
        let ipadScreenshots = readinessScreenshotSets.first { $0.attributes.screenshotDisplayType == "APP_IPAD_PRO_3GEN_129" }

        let privacyUrl: String? = app.map {
            "https://appstoreconnect.apple.com/apps/\($0.id)/distribution/privacy"
        }

        func readinessField(
            label: String,
            value: String?,
            required: Bool = true,
            actionUrl: String? = nil,
            hint: String? = nil
        ) -> SubmissionReadiness.FieldStatus {
            SubmissionReadiness.FieldStatus(
                label: label,
                value: value,
                isLoading: overviewReadinessLoadingFields.contains(label) && (value == nil || value?.isEmpty == true),
                required: required,
                actionUrl: actionUrl,
                hint: hint
            )
        }

        var fields: [SubmissionReadiness.FieldStatus] = [
            readinessField(label: "App Name", value: appInfoLocalization?.attributes.name ?? localization?.attributes.title),
            readinessField(label: "Description", value: localization?.attributes.description),
            readinessField(label: "Keywords", value: localization?.attributes.keywords),
            readinessField(label: "Support URL", value: localization?.attributes.supportUrl),
        ]

        fields.append(contentsOf: whatsNewReadinessFields())

        fields.append(contentsOf: [
            readinessField(label: "Privacy Policy URL", value: appInfoLocalization?.attributes.privacyPolicyUrl),
            readinessField(label: "Copyright", value: version?.attributes.copyright),
            readinessField(label: "Content Rights", value: app?.contentRightsDeclaration),
            readinessField(label: "Primary Category", value: appInfo?.primaryCategoryId),
            readinessField(label: "Age Rating", value: ageRatingIsConfigured ? "Configured" : nil),
            readinessField(label: "Pricing", value: monetizationStatus),
            readinessField(label: "Review Contact First Name", value: review?.attributes.contactFirstName),
            readinessField(label: "Review Contact Last Name", value: review?.attributes.contactLastName),
            readinessField(label: "Review Contact Email", value: review?.attributes.contactEmail),
            readinessField(label: "Review Contact Phone", value: review?.attributes.contactPhone),
        ])

        if demoRequired {
            fields.append(readinessField(label: "Demo Account Name", value: review?.attributes.demoAccountName))
            fields.append(readinessField(label: "Demo Account Password", value: review?.attributes.demoAccountPassword))
        }

        fields.append(readinessField(label: "App Icon", value: appIconStatus))

        func validCount(for set: ASCScreenshotSet?) -> Int {
            guard let set else { return 0 }
            if let screenshots = readinessScreenshots[set.id] {
                return screenshots.filter { !$0.hasError }.count
            }
            return set.attributes.screenshotCount ?? 0
        }

        if isMacApp {
            let macCount = validCount(for: macScreenshots)
            fields.append(readinessField(label: "Mac Screenshots", value: macCount > 0 ? "\(macCount) screenshot(s)" : nil))
        } else {
            let iphoneCount = validCount(for: iphoneScreenshots)
            let ipadCount = validCount(for: ipadScreenshots)
            fields.append(readinessField(label: "iPhone Screenshots", value: iphoneCount > 0 ? "\(iphoneCount) screenshot(s)" : nil))
            fields.append(readinessField(label: "iPad Screenshots", value: ipadCount > 0 ? "\(ipadCount) screenshot(s)" : nil))
        }

        fields.append(contentsOf: [
            readinessField(label: "Privacy Nutrition Labels", value: nil, required: false, actionUrl: privacyUrl),
            readinessField(label: "Build", value: selectedVersionBuild?.attributes.version),
        ])

        let approvedStates: Set<String> = [
            "READY_FOR_SALE",
            "REMOVED_FROM_SALE",
            "DEVELOPER_REMOVED_FROM_SALE",
            "REPLACED_WITH_NEW_VERSION",
            "PROCESSING_FOR_APP_STORE"
        ]
        let hasApprovedVersion = appStoreVersions.contains {
            approvedStates.contains($0.attributes.appStoreState ?? "")
        }
        let isFirstVersion = !hasApprovedVersion
        if isFirstVersion {
            let readyIAPs = inAppPurchases.filter {
                $0.attributes.state == "READY_TO_SUBMIT" && !attachedSubmissionItemIDs.contains($0.id)
            }
            let readySubscriptions = subscriptionsPerGroup.values.flatMap { $0 }
                .filter {
                    $0.attributes.state == "READY_TO_SUBMIT" && !attachedSubmissionItemIDs.contains($0.id)
                }
            let readyCount = readyIAPs.count + readySubscriptions.count
            if readyCount > 0 {
                let names = (readyIAPs.map { $0.attributes.name ?? $0.attributes.productId ?? $0.id }
                    + readySubscriptions.map { $0.attributes.name ?? $0.attributes.productId ?? $0.id })
                    .joined(separator: ", ")
                let iapUrl: String? = app.map {
                    "https://appstoreconnect.apple.com/apps/\($0.id)/distribution/ios/version/inflight"
                }
                fields.append(readinessField(
                    label: "In-App Purchases & Subscriptions",
                    value: nil,
                    required: true,
                    actionUrl: iapUrl,
                    hint: "\(readyCount) item(s) in Ready to Submit state (\(names)) must be attached to this version before submission. "
                        + "Use the asc-iap-attach skill to attach them via the iris API (asc web session). "
                        + "The public API does not support first-time IAP/subscription attachment - "
                        + "run: asc web auth login, then POST to /iris/v1/subscriptionSubmissions or /iris/v1/inAppPurchaseSubmissions "
                        + "with submitWithNextAppStoreVersion:true for each item."
                ))
            }
        }

        return SubmissionReadiness(fields: fields)
    }
}

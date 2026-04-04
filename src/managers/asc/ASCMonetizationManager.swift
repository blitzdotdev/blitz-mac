import Foundation

// MARK: - Monetization Manager
// Extension containing monetization-related functionality for ASCManager

extension ASCManager {
    // MARK: - IAP Creation

    func createIAP(name: String, productId: String, type: String, displayName: String, description: String?, price: String, screenshotPath: String? = nil) {
        guard let service else { return }
        guard let appId = app?.id else { return }
        let startedAt = Date()
        writeError = nil
        isCreating = true
        createProgress = 0
        createProgressMessage = "Creating in-app purchase…"

        createTask = Task { [weak self] in
            guard let self else { return }
            do {
                createProgress = 0.05
                let iap = try await service.createInAppPurchase(
                    appId: appId, name: name, productId: productId, inAppPurchaseType: type
                )

                createProgressMessage = "Setting localization…"
                createProgress = 0.15
                try await service.localizeInAppPurchase(
                    iapId: iap.id, locale: "en-US", name: displayName, description: description
                )

                createProgressMessage = "Setting availability…"
                createProgress = 0.3
                let territories = try await service.fetchAllTerritories()
                try await service.createIAPAvailability(iapId: iap.id, territoryIds: territories)

                createProgress = 0.5
                if !price.isEmpty, let priceVal = Double(price), priceVal > 0 {
                    createProgressMessage = "Setting price…"
                    let points = try await service.fetchInAppPurchasePricePoints(iapId: iap.id)
                    if let match = points.first(where: {
                        guard let cp = $0.attributes.customerPrice, let cpVal = Double(cp) else { return false }
                        return abs(cpVal - priceVal) < 0.001
                    }) {
                        try await service.setInAppPurchasePrice(iapId: iap.id, pricePointId: match.id)
                    }
                }

                createProgress = 0.7
                if let path = screenshotPath {
                    createProgressMessage = "Uploading screenshot…"
                    try await service.uploadIAPReviewScreenshot(iapId: iap.id, path: path)
                }

                createProgressMessage = "Waiting for status update…"
                createProgress = 0.9
                try await pollRefreshIAPs(service: service, appId: appId)
                createProgress = 1.0
                AnalyticsService.trackBlitzManagedASCUsage(
                    commandType: "iap.create",
                    success: true,
                    startedAt: startedAt
                )
            } catch {
                writeError = error.localizedDescription
                AnalyticsService.trackBlitzManagedASCUsage(
                    commandType: "iap.create",
                    success: false,
                    startedAt: startedAt
                )
            }
            isCreating = false
            createProgress = 0
            createProgressMessage = ""
        }
    }

    // MARK: - IAP Updates

    func updateIAP(id: String, name: String?, reviewNote: String?, displayName: String?, description: String?) async {
        guard let service else { return }
        guard let appId = app?.id else { return }
        let startedAt = Date()
        writeError = nil
        do {
            // Patch IAP attributes (name, reviewNote)
            var attrs: [String: Any] = [:]
            if let name { attrs["name"] = name }
            if let reviewNote { attrs["reviewNote"] = reviewNote }
            if !attrs.isEmpty {
                try await service.patchInAppPurchase(iapId: id, attrs: attrs)
            }
            // Patch localization (displayName, description)
            if displayName != nil || description != nil {
                let locs = try await service.fetchIAPLocalizations(iapId: id)
                if let loc = locs.first {
                    var fields: [String: String] = [:]
                    if let displayName { fields["name"] = displayName }
                    if let description { fields["description"] = description }
                    try await service.patchIAPLocalization(locId: loc.id, fields: fields)
                }
            }
            inAppPurchases = try await service.fetchInAppPurchases(appId: appId)
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "iap.update",
                success: true,
                startedAt: startedAt
            )
        } catch {
            writeError = error.localizedDescription
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "iap.update",
                success: false,
                startedAt: startedAt
            )
        }
    }

    // MARK: - IAP Deletion

    func deleteIAP(id: String) async {
        guard let service else { return }
        guard let appId = app?.id else { return }
        let startedAt = Date()
        writeError = nil
        do {
            try await service.deleteInAppPurchase(iapId: id)
            inAppPurchases = try await service.fetchInAppPurchases(appId: appId)
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "iap.delete",
                success: true,
                startedAt: startedAt
            )
        } catch {
            writeError = error.localizedDescription
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "iap.delete",
                success: false,
                startedAt: startedAt
            )
        }
    }

    // MARK: - IAP Screenshots

    func uploadIAPScreenshot(iapId: String, path: String) async {
        guard let service else { return }
        let startedAt = Date()
        writeError = nil
        do {
            try await service.uploadIAPReviewScreenshot(iapId: iapId, path: path)
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "iap.screenshot.upload",
                success: true,
                startedAt: startedAt
            )
        } catch {
            writeError = error.localizedDescription
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "iap.screenshot.upload",
                success: false,
                startedAt: startedAt
            )
        }
    }

    // MARK: - IAP Submission

    func submitIAPForReview(id: String) async -> Bool {
        guard let service else { return false }
        guard let appId = app?.id else { return false }
        let startedAt = Date()
        writeError = nil
        do {
            try await service.submitIAPForReview(iapId: id)
            inAppPurchases = try await service.fetchInAppPurchases(appId: appId)
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "iap.submit_for_review",
                success: true,
                startedAt: startedAt
            )
            return true
        } catch {
            let msg = error.localizedDescription
            if msg.contains("FIRST_IAP") || msg.contains("first In-App Purchase") || msg.contains("first in-app purchase") {
                writeError = "FIRST_SUBMISSION:" + msg
            } else {
                writeError = msg
            }
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "iap.submit_for_review",
                success: false,
                startedAt: startedAt
            )
            return false
        }
    }

    // MARK: - Subscription Creation

    func createSubscription(groupName: String, name: String, productId: String, displayName: String, description: String?, duration: String, price: String, screenshotPath: String? = nil) {
        guard let service else { return }
        guard let appId = app?.id else { return }
        let startedAt = Date()
        writeError = nil
        isCreating = true
        createProgress = 0
        createProgressMessage = "Setting up group…"

        createTask = Task { [weak self] in
            guard let self else { return }
            do {
                createProgress = 0.03
                let group: ASCSubscriptionGroup
                if let existing = subscriptionGroups.first(where: { $0.attributes.referenceName == groupName }) {
                    let groupLocs = try await service.fetchSubscriptionGroupLocalizations(groupId: existing.id)
                    if groupLocs.isEmpty {
                        try await service.localizeSubscriptionGroup(groupId: existing.id, locale: "en-US", name: groupName)
                    }
                    group = existing
                } else {
                    group = try await service.createSubscriptionGroup(appId: appId, referenceName: groupName)
                    try await service.localizeSubscriptionGroup(groupId: group.id, locale: "en-US", name: groupName)
                }

                createProgressMessage = "Creating subscription…"
                createProgress = 0.08
                let sub = try await service.createSubscription(
                    groupId: group.id, name: name, productId: productId, subscriptionPeriod: duration
                )

                createProgressMessage = "Setting localization…"
                createProgress = 0.12
                try await service.localizeSubscription(
                    subscriptionId: sub.id, locale: "en-US", name: displayName, description: description
                )

                createProgressMessage = "Setting availability…"
                createProgress = 0.16
                let territories = try await service.fetchAllTerritories()
                try await service.createSubscriptionAvailability(subscriptionId: sub.id, territoryIds: territories)

                createProgress = 0.2
                if !price.isEmpty, let priceVal = Double(price), priceVal > 0 {
                    let points = try await service.fetchSubscriptionPricePoints(subscriptionId: sub.id)
                    if let match = points.first(where: {
                        guard let cp = $0.attributes.customerPrice, let cpVal = Double(cp) else { return false }
                        return abs(cpVal - priceVal) < 0.001
                    }) {
                        // Pricing loop: 0.2 → 0.8 (bulk of the time)
                        createProgressMessage = "Setting prices (0/175)…"
                        try await service.setSubscriptionPrice(subscriptionId: sub.id, pricePointId: match.id) { done, total in
                            Task { @MainActor [weak self] in
                                self?.createProgressMessage = "Setting prices (\(done)/\(total))…"
                                self?.createProgress = 0.2 + 0.6 * (Double(done) / Double(total))
                            }
                        }
                    }
                }

                createProgress = 0.85
                if let path = screenshotPath {
                    createProgressMessage = "Uploading screenshot…"
                    try await service.uploadSubscriptionReviewScreenshot(subscriptionId: sub.id, path: path)
                }

                createProgressMessage = "Waiting for status update…"
                createProgress = 0.9
                try await pollRefreshSubscriptions(service: service, appId: appId)
                createProgress = 1.0
                AnalyticsService.trackBlitzManagedASCUsage(
                    commandType: "subscription.create",
                    success: true,
                    startedAt: startedAt
                )
            } catch {
                writeError = error.localizedDescription
                AnalyticsService.trackBlitzManagedASCUsage(
                    commandType: "subscription.create",
                    success: false,
                    startedAt: startedAt
                )
            }
            isCreating = false
            createProgress = 0
            createProgressMessage = ""
        }
    }

    // MARK: - Subscription Updates

    func updateSubscription(id: String, name: String?, reviewNote: String?, displayName: String?, description: String?) async {
        guard let service else { return }
        guard let appId = app?.id else { return }
        let startedAt = Date()
        writeError = nil
        do {
            var attrs: [String: Any] = [:]
            if let name { attrs["name"] = name }
            if let reviewNote { attrs["reviewNote"] = reviewNote }
            if !attrs.isEmpty {
                try await service.patchSubscription(subscriptionId: id, attrs: attrs)
            }
            if displayName != nil || description != nil {
                let locs = try await service.fetchSubscriptionLocalizations(subscriptionId: id)
                if let loc = locs.first {
                    var fields: [String: String] = [:]
                    if let displayName { fields["name"] = displayName }
                    if let description { fields["description"] = description }
                    try await service.patchSubscriptionLocalization(locId: loc.id, fields: fields)
                }
            }
            subscriptionGroups = try await service.fetchSubscriptionGroups(appId: appId)
            for g in subscriptionGroups {
                subscriptionsPerGroup[g.id] = try await service.fetchSubscriptionsInGroup(groupId: g.id)
            }
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "subscription.update",
                success: true,
                startedAt: startedAt
            )
        } catch {
            writeError = error.localizedDescription
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "subscription.update",
                success: false,
                startedAt: startedAt
            )
        }
    }

    // MARK: - Subscription Deletion

    func deleteSubscription(id: String) async {
        guard let service else { return }
        guard let appId = app?.id else { return }
        let startedAt = Date()
        writeError = nil
        do {
            try await service.deleteSubscription(subscriptionId: id)
            subscriptionGroups = try await service.fetchSubscriptionGroups(appId: appId)
            for g in subscriptionGroups {
                subscriptionsPerGroup[g.id] = try await service.fetchSubscriptionsInGroup(groupId: g.id)
            }
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "subscription.delete",
                success: true,
                startedAt: startedAt
            )
        } catch {
            writeError = error.localizedDescription
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "subscription.delete",
                success: false,
                startedAt: startedAt
            )
        }
    }

    func deleteSubscriptionGroup(id: String) async {
        guard let service else { return }
        guard let appId = app?.id else { return }
        let startedAt = Date()
        writeError = nil
        do {
            try await service.deleteSubscriptionGroup(groupId: id)
            subscriptionGroups = try await service.fetchSubscriptionGroups(appId: appId)
            subscriptionsPerGroup.removeValue(forKey: id)
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "subscription_group.delete",
                success: true,
                startedAt: startedAt
            )
        } catch {
            writeError = error.localizedDescription
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "subscription_group.delete",
                success: false,
                startedAt: startedAt
            )
        }
    }

    // MARK: - Subscription Screenshots

    func uploadSubscriptionScreenshot(subscriptionId: String, path: String) async {
        guard let service else { return }
        let startedAt = Date()
        writeError = nil
        do {
            try await service.uploadSubscriptionReviewScreenshot(subscriptionId: subscriptionId, path: path)
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "subscription.screenshot.upload",
                success: true,
                startedAt: startedAt
            )
        } catch {
            writeError = error.localizedDescription
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "subscription.screenshot.upload",
                success: false,
                startedAt: startedAt
            )
        }
    }

    // MARK: - Subscription Localization

    func updateSubscriptionGroupLocalization(groupId: String, name: String) async {
        guard let service else { return }
        let startedAt = Date()
        writeError = nil
        do {
            let locs = try await service.fetchSubscriptionGroupLocalizations(groupId: groupId)
            if let loc = locs.first {
                try await service.patchSubscriptionGroupLocalization(locId: loc.id, name: name)
            } else {
                try await service.localizeSubscriptionGroup(groupId: groupId, locale: "en-US", name: name)
            }
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "subscription_group.update",
                success: true,
                startedAt: startedAt
            )
        } catch {
            writeError = error.localizedDescription
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "subscription_group.update",
                success: false,
                startedAt: startedAt
            )
        }
    }

    // MARK: - Subscription Submission

    func submitSubscriptionForReview(id: String) async -> Bool {
        guard let service else { return false }
        guard let appId = app?.id else { return false }
        let startedAt = Date()
        writeError = nil
        do {
            try await service.submitSubscriptionForReview(subscriptionId: id)
            subscriptionGroups = try await service.fetchSubscriptionGroups(appId: appId)
            for g in subscriptionGroups {
                subscriptionsPerGroup[g.id] = try await service.fetchSubscriptionsInGroup(groupId: g.id)
            }
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "subscription.submit_for_review",
                success: true,
                startedAt: startedAt
            )
            return true
        } catch {
            let msg = error.localizedDescription
            if msg.contains("FIRST_SUBSCRIPTION") || msg.contains("first subscription") {
                writeError = "FIRST_SUBMISSION:" + msg
            } else {
                writeError = msg
            }
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "subscription.submit_for_review",
                success: false,
                startedAt: startedAt
            )
            return false
        }
    }

    // MARK: - Pricing

    func setAppPrice(pricePointId: String) async {
        guard let service else { return }
        guard let appId = app?.id else { return }
        let startedAt = Date()
        writeError = nil
        do {
            try await service.setAppPrice(appId: appId, pricePointId: pricePointId)
            try await service.ensureAppAvailability(appId: appId)
            currentAppPricePointId = pricePointId
            scheduledAppPricePointId = nil
            scheduledAppPriceEffectiveDate = nil
            monetizationStatus = isFreePricePoint(pricePointId) ? "Free" : "Configured"
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "app_price.set",
                success: true,
                startedAt: startedAt
            )
        } catch {
            writeError = error.localizedDescription
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "app_price.set",
                success: false,
                startedAt: startedAt
            )
        }
    }

    func setScheduledAppPrice(currentPricePointId: String, futurePricePointId: String, effectiveDate: String) async {
        guard let service else { return }
        guard let appId = app?.id else { return }
        let startedAt = Date()
        writeError = nil
        do {
            try await service.setScheduledAppPrice(
                appId: appId,
                currentPricePointId: currentPricePointId,
                futurePricePointId: futurePricePointId,
                effectiveDate: effectiveDate
            )
            self.currentAppPricePointId = currentPricePointId
            scheduledAppPricePointId = futurePricePointId
            scheduledAppPriceEffectiveDate = effectiveDate
            monetizationStatus = "Configured"
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "app_price.schedule",
                success: true,
                startedAt: startedAt
            )
        } catch {
            writeError = error.localizedDescription
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "app_price.schedule",
                success: false,
                startedAt: startedAt
            )
        }
    }

    func setPriceFree() async {
        guard let service else { return }
        guard let appId = app?.id else { return }
        let startedAt = Date()
        writeError = nil
        do {
            try await service.setPriceFree(appId: appId)
            try await service.ensureAppAvailability(appId: appId)
            currentAppPricePointId = freeAppPricePointId
            scheduledAppPricePointId = nil
            scheduledAppPriceEffectiveDate = nil
            monetizationStatus = "Free"
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "app_price.free",
                success: true,
                startedAt: startedAt
            )
        } catch {
            writeError = error.localizedDescription
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "app_price.free",
                success: false,
                startedAt: startedAt
            )
        }
    }

    // MARK: - Refresh

    func refreshMonetization() async {
        guard let service else { return }
        guard let appId = app?.id else { return }
        await ASCUpdateLogger.shared.event("monetization_refresh_started", metadata: [
            "appId": appId,
        ])
        do {
            inAppPurchases = try await service.fetchInAppPurchases(appId: appId)
            subscriptionGroups = try await service.fetchSubscriptionGroups(appId: appId)
            for group in subscriptionGroups {
                subscriptionsPerGroup[group.id] = try await service.fetchSubscriptionsInGroup(groupId: group.id)
            }
            await ASCUpdateLogger.shared.event("monetization_refresh_succeeded", metadata: [
                "appId": appId,
                "inAppPurchaseCount": String(inAppPurchases.count),
                "subscriptionGroupCount": String(subscriptionGroups.count),
            ])
        } catch {
            writeError = error.localizedDescription
            await logDataFetchFailure("monetization_refresh_failed", error: error, metadata: [
                "appId": appId,
            ])
        }
    }

    func refreshAttachedSubmissionItemIDs() async {
        guard let appId = app?.id else {
            attachedSubmissionItemIDs = []
            return
        }
        guard let cookieHeader = ascWebSessionCookieHeader() else {
            attachedSubmissionItemIDs = []
            return
        }

        let subscriptionURL = "https://appstoreconnect.apple.com/iris/v1/apps/\(appId)/subscriptionGroups?include=subscriptions&limit=300&fields%5Bsubscriptions%5D=productId,name,state,submitWithNextAppStoreVersion"
        let iapURL = "https://appstoreconnect.apple.com/iris/v1/apps/\(appId)/inAppPurchasesV2?limit=300&fields%5BinAppPurchases%5D=productId,name,state,submitWithNextAppStoreVersion"

        let attachedSubscriptions = await fetchAttachedSubmissionItemIDs(urlString: subscriptionURL, cookieHeader: cookieHeader)
        let attachedIAPs = await fetchAttachedSubmissionItemIDs(urlString: iapURL, cookieHeader: cookieHeader)
        attachedSubmissionItemIDs = attachedSubscriptions.union(attachedIAPs)
    }

    // MARK: - Polling

    private func pollRefreshIAPs(service: AppStoreConnectService, appId: String) async throws {
        for _ in 0..<5 {
            try await Task.sleep(for: .seconds(1))
            inAppPurchases = try await service.fetchInAppPurchases(appId: appId)
            let allResolved = inAppPurchases.allSatisfy { $0.attributes.state != "MISSING_METADATA" }
            if allResolved { return }
        }
    }

    private func pollRefreshSubscriptions(service: AppStoreConnectService, appId: String) async throws {
        for _ in 0..<5 {
            try await Task.sleep(for: .seconds(1))
            subscriptionGroups = try await service.fetchSubscriptionGroups(appId: appId)
            for g in subscriptionGroups {
                subscriptionsPerGroup[g.id] = try await service.fetchSubscriptionsInGroup(groupId: g.id)
            }
            let allResolved = subscriptionsPerGroup.values.joined().allSatisfy { $0.attributes.state != "MISSING_METADATA" }
            if allResolved { return }
        }
    }

    // MARK: - Pricing State

    var freeAppPricePointId: String? {
        appPricePoints.first(where: {
            let price = $0.attributes.customerPrice ?? "0"
            return price == "0" || price == "0.0" || price == "0.00"
        })?.id
    }

    func applyAppPricingState(_ state: ASCAppPricingState) {
        currentAppPricePointId = state.currentPricePointId
        scheduledAppPricePointId = state.scheduledPricePointId
        scheduledAppPriceEffectiveDate = state.scheduledEffectiveDate

        if let currentPricePointId = currentAppPricePointId {
            let isCurrentlyFree = isFreePricePoint(currentPricePointId)
            monetizationStatus = (isCurrentlyFree && state.scheduledPricePointId == nil) ? "Free" : "Configured"
        } else if state.scheduledPricePointId != nil {
            monetizationStatus = "Configured"
        } else {
            monetizationStatus = nil
        }
    }

    func isFreePricePoint(_ pricePointId: String) -> Bool {
        appPricePoints.contains(where: {
            guard $0.id == pricePointId else { return false }
            let price = $0.attributes.customerPrice ?? "0"
            return price == "0" || price == "0.0" || price == "0.00"
        })
    }

    // MARK: - Web Session Helpers (for IAP attachment queries)

    func ascWebSessionCookieHeader() -> String? {
        guard let storeData = Self.readKeychainItem(service: "asc-web-session", account: "asc:web-session:store"),
              let store = try? JSONSerialization.jsonObject(with: storeData) as? [String: Any],
              let lastKey = store["last_key"] as? String,
              let sessions = store["sessions"] as? [String: Any],
              let sessionDict = sessions[lastKey] as? [String: Any],
              let cookies = sessionDict["cookies"] as? [String: [[String: Any]]] else {
            return nil
        }

        let cookieHeader = cookies.values.flatMap { $0 }.compactMap { cookie -> String? in
            guard let name = cookie["name"] as? String,
                  let value = cookie["value"] as? String,
                  !name.isEmpty else { return nil }
            return name.hasPrefix("DES") ? "\(name)=\"\(value)\"" : "\(name)=\(value)"
        }.joined(separator: "; ")

        return cookieHeader.isEmpty ? nil : cookieHeader
    }

    func fetchAttachedSubmissionItemIDs(urlString: String, cookieHeader: String) async -> Set<String> {
        guard let url = URL(string: urlString) else { return [] }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("https://appstoreconnect.apple.com", forHTTPHeaderField: "Origin")
        request.setValue("https://appstoreconnect.apple.com/", forHTTPHeaderField: "Referer")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        let resources = (json["data"] as? [[String: Any]] ?? [])
            + (json["included"] as? [[String: Any]] ?? [])

        return Set(resources.compactMap { item in
            guard let attrs = item["attributes"] as? [String: Any],
                  let id = item["id"] as? String,
                  let submitWithNext = attrs["submitWithNextAppStoreVersion"] as? Bool,
                  submitWithNext else { return nil }
            return id
        })
    }
}

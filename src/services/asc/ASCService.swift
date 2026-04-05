import Foundation

final class AppStoreConnectService {
    private let client: ASCDaemonClient
    private let session = URLSession.shared
    private let updateLogger = ASCUpdateLogger.shared

    init(credentials: ASCCredentials) {
        self.client = ASCDaemonClient(credentials: credentials)
    }

    func cliExec(args: [String]) async throws -> (exitCode: Int, stdout: String, stderr: String) {
        try await client.cliExec(args: args)
    }

    // MARK: - HTTP

    /// Centralized request path so every ASC call gets the same request/response logging.
    private func performRequest(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        headers: [String: String],
        body: Data? = nil
    ) async throws -> ASCDaemonClient.HTTPResponse {
        let resolvedPath = try resolvedPath(path, queryItems: queryItems)
        let requestId = UUID().uuidString
        await updateLogger.request(id: requestId, method: method, path: resolvedPath, body: body)

        do {
            let response = try await client.request(
                method: method,
                path: resolvedPath,
                headers: headers,
                body: body
            )
            await updateLogger.response(
                id: requestId,
                method: method,
                path: resolvedPath,
                statusCode: response.statusCode,
                body: response.body
            )
            return response
        } catch {
            await updateLogger.failure(id: requestId, method: method, path: resolvedPath, error: error)
            throw error
        }
    }

    private func resolvedPath(_ rawPath: String, queryItems: [URLQueryItem] = []) throws -> String {
        let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { throw ASCError.invalidURL }

        if trimmedPath.hasPrefix("http://") || trimmedPath.hasPrefix("https://") {
            guard var components = URLComponents(string: trimmedPath) else {
                throw ASCError.invalidURL
            }
            if !queryItems.isEmpty {
                components.queryItems = (components.queryItems ?? []) + queryItems
            }
            guard let path = components.string else { throw ASCError.invalidURL }
            return path
        }

        var components = URLComponents()
        components.path = trimmedPath.hasPrefix("/") ? trimmedPath : "/v1/\(trimmedPath)"
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let path = components.string else { throw ASCError.invalidURL }
        return path
    }

    private func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem] = [], as type: T.Type) async throws -> T {
        let response = try await performRequest(
            method: "GET",
            path: path,
            queryItems: queryItems,
            headers: ["Accept": "application/json"]
        )
        if !(200..<300).contains(response.statusCode) {
            let body = String(data: response.body, encoding: .utf8) ?? ""
            throw ASCError.httpError(response.statusCode, body)
        }
        return try JSONDecoder().decode(T.self, from: response.body)
    }

    private func patch(path: String, body: [String: Any]) async throws {
        let response = try await performRequest(
            method: "PATCH",
            path: path,
            headers: [
                "Accept": "application/json",
                "Content-Type": "application/json",
            ],
            body: try JSONSerialization.data(withJSONObject: body)
        )
        if !(200..<300).contains(response.statusCode) {
            let body = String(data: response.body, encoding: .utf8) ?? ""
            throw ASCError.httpError(response.statusCode, body)
        }
    }

    private func patchData(path: String, body: [String: Any]) async throws -> Data {
        let response = try await performRequest(
            method: "PATCH",
            path: path,
            headers: [
                "Accept": "application/json",
                "Content-Type": "application/json",
            ],
            body: try JSONSerialization.data(withJSONObject: body)
        )
        if !(200..<300).contains(response.statusCode) {
            let body = String(data: response.body, encoding: .utf8) ?? ""
            throw ASCError.httpError(response.statusCode, body)
        }
        return response.body
    }

    private func post(path: String, body: [String: Any]) async throws -> Data {
        let response = try await performRequest(
            method: "POST",
            path: path,
            headers: [
                "Accept": "application/json",
                "Content-Type": "application/json",
            ],
            body: try JSONSerialization.data(withJSONObject: body)
        )
        if !(200..<300).contains(response.statusCode) {
            let body = String(data: response.body, encoding: .utf8) ?? ""
            throw ASCError.httpError(response.statusCode, body)
        }
        return response.body
    }

    private func delete(path: String) async throws {
        let response = try await performRequest(
            method: "DELETE",
            path: path,
            headers: ["Accept": "application/json"]
        )
        if !(200..<300).contains(response.statusCode) {
            let body = String(data: response.body, encoding: .utf8) ?? ""
            throw ASCError.httpError(response.statusCode, body)
        }
    }

    func deleteScreenshot(screenshotId: String) async throws {
        try await delete(path: "appScreenshots/\(screenshotId)")
    }

    private func get<T: Decodable>(fullPath: String, queryItems: [URLQueryItem] = [], as type: T.Type) async throws -> T {
        try await get(fullPath, queryItems: queryItems, as: type)
    }

    private func post(fullPath: String, body: [String: Any]) async throws -> Data {
        try await post(path: fullPath, body: body)
    }

    private func patch(fullPath: String, body: [String: Any]) async throws {
        try await patch(path: fullPath, body: body)
    }

    private func delete(fullPath: String) async throws {
        try await delete(path: fullPath)
    }

    private func upload(url: URL, method: String, headers: [String: String], body: Data) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body

        let requestId = UUID().uuidString
        await updateLogger.request(id: requestId, method: method, path: url.absoluteString, body: body)

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                await updateLogger.response(
                    id: requestId,
                    method: method,
                    path: url.absoluteString,
                    statusCode: http.statusCode,
                    body: data
                )
                if !(200..<300).contains(http.statusCode) {
                    let respBody = String(data: data, encoding: .utf8) ?? ""
                    throw ASCError.httpError(http.statusCode, respBody)
                }
            }
        } catch {
            await updateLogger.failure(id: requestId, method: method, path: url.absoluteString, error: error)
            throw error
        }
    }

    // MARK: - App

    func fetchApp(bundleId: String, exactName: String? = nil) async throws -> ASCApp {
        let trimmedBundleId = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBundleId.isEmpty else {
            throw ASCError.notFound("App with a valid bundle ID")
        }

        let resp = try await get("apps", queryItems: [
            URLQueryItem(name: "filter[bundleId]", value: trimmedBundleId),
            URLQueryItem(name: "limit", value: "1")
        ], as: ASCListResponse<ASCApp>.self)
        guard let app = resp.data.first else {
            throw ASCError.notFound("App with bundle ID '\(trimmedBundleId)'")
        }

        if let exactName {
            let trimmedExpectedName = exactName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedExpectedName.isEmpty {
                let actualName = app.attributes.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard actualName == trimmedExpectedName else {
                    throw ASCError.notFound("App named '\(trimmedExpectedName)' with bundle ID '\(trimmedBundleId)'")
                }
            }
        }
        return app
    }

    func fetchApp(id: String) async throws -> ASCApp {
        let trimmedId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else {
            throw ASCError.notFound("App with a valid ID")
        }

        let response = try await get(
            "apps/\(trimmedId)",
            queryItems: [
                URLQueryItem(
                    name: "fields[apps]",
                    value: "bundleId,name,primaryLocale,contentRightsDeclaration"
                )
            ],
            as: ASCSingleResponse<ASCApp>.self
        )
        return response.data
    }

    /// Fetches all apps for the account, optionally filtering by app store version state.
    /// Pass `appStoreStateFilter: "READY_FOR_SALE"` to get only live apps.
    func fetchAllApps(appStoreStateFilter: String? = nil) async throws -> [ASCApp] {
        var allApps: [ASCApp] = []
        var nextPath: String? = nil

        var initialQueryItems: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: "200"),
            URLQueryItem(name: "fields[apps]", value: "bundleId,name,primaryLocale")
        ]
        if let state = appStoreStateFilter {
            initialQueryItems.append(URLQueryItem(name: "filter[appStoreVersions.appStoreState]", value: state))
        }

        repeat {
            let resp: ASCPaginatedResponse<ASCApp>
            if let path = nextPath {
                resp = try await get(path, as: ASCPaginatedResponse<ASCApp>.self)
            } else {
                resp = try await get("apps", queryItems: initialQueryItems, as: ASCPaginatedResponse<ASCApp>.self)
            }
            allApps.append(contentsOf: resp.data)
            nextPath = resp.links?.next
        } while nextPath != nil

        return allApps
    }

    // MARK: - App Store Versions

    func fetchAppStoreVersions(appId: String) async throws -> [ASCAppStoreVersion] {
        let resp = try await get("apps/\(appId)/appStoreVersions", queryItems: [
            URLQueryItem(name: "limit", value: "50")
        ], as: ASCListResponse<ASCAppStoreVersion>.self)
        return ASCReleaseStatus.sortedVersionsByRecency(resp.data)
    }

    // MARK: - Localizations

    func fetchLocalizations(versionId: String) async throws -> [ASCVersionLocalization] {
        let resp = try await get(
            "appStoreVersions/\(versionId)/appStoreVersionLocalizations",
            as: ASCListResponse<ASCVersionLocalization>.self
        )
        return resp.data
    }

    // MARK: - Screenshots

    func fetchScreenshotSets(localizationId: String) async throws -> [ASCScreenshotSet] {
        let resp = try await get(
            "appStoreVersionLocalizations/\(localizationId)/appScreenshotSets",
            as: ASCListResponse<ASCScreenshotSet>.self
        )
        return resp.data
    }

    func fetchScreenshots(setId: String) async throws -> [ASCScreenshot] {
        let resp = try await get(
            "appScreenshotSets/\(setId)/appScreenshots",
            as: ASCListResponse<ASCScreenshot>.self
        )
        return resp.data
    }

    // MARK: - Customer Reviews

    func fetchCustomerReviews(appId: String) async throws -> [ASCCustomerReview] {
        let resp = try await get("apps/\(appId)/customerReviews", queryItems: [
            URLQueryItem(name: "sort", value: "-createdDate"),
            URLQueryItem(name: "limit", value: "50")
        ], as: ASCListResponse<ASCCustomerReview>.self)
        return resp.data
    }

    // MARK: - Builds

    func fetchBuilds(appId: String) async throws -> [ASCBuild] {
        let resp = try await get("builds", queryItems: [
            URLQueryItem(name: "filter[app]", value: appId),
            URLQueryItem(name: "sort", value: "-uploadedDate"),
            URLQueryItem(name: "limit", value: "50")
        ], as: ASCListResponse<ASCBuild>.self)
        return resp.data
    }

    func fetchBuild(id: String) async throws -> ASCBuild {
        let resp = try await get("builds/\(id)", as: ASCSingleResponse<ASCBuild>.self)
        return resp.data
    }

    func fetchBuildUploads(
        appId: String,
        shortVersion: String,
        buildNumber: String,
        platform: String,
        limit: Int = 20
    ) async throws -> [ASCBuildUpload] {
        let resp = try await get("buildUploads", queryItems: [
            URLQueryItem(name: "filter[app]", value: appId),
            URLQueryItem(name: "filter[cfBundleShortVersionString]", value: shortVersion),
            URLQueryItem(name: "filter[cfBundleVersion]", value: buildNumber),
            URLQueryItem(name: "filter[platform]", value: platform),
            URLQueryItem(name: "sort", value: "-uploadedDate"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "include", value: "build"),
        ], as: ASCListResponse<ASCBuildUpload>.self)
        return resp.data
    }

    func fetchBuildUpload(id: String) async throws -> ASCBuildUpload {
        let resp = try await get(
            "buildUploads/\(id)",
            queryItems: [URLQueryItem(name: "include", value: "build")],
            as: ASCSingleResponse<ASCBuildUpload>.self
        )
        return resp.data
    }

    // MARK: - Beta Groups

    func fetchBetaGroups(appId: String) async throws -> [ASCBetaGroup] {
        let resp = try await get(
            "apps/\(appId)/betaGroups",
            as: ASCListResponse<ASCBetaGroup>.self
        )
        return resp.data
    }

    // MARK: - Beta Localizations

    func fetchBetaLocalizations(appId: String) async throws -> [ASCBetaLocalization] {
        let resp = try await get(
            "apps/\(appId)/betaAppLocalizations",
            as: ASCListResponse<ASCBetaLocalization>.self
        )
        return resp.data
    }

    func patchBetaLocalization(id: String, locale: String, description: String?,
                               feedbackEmail: String?, marketingUrl: String?,
                               privacyPolicyUrl: String?) async throws {
        var attrs: [String: Any] = [:]
        if let v = description { attrs["description"] = v }
        if let v = feedbackEmail { attrs["feedbackEmail"] = v }
        if let v = marketingUrl { attrs["marketingUrl"] = v }
        if let v = privacyPolicyUrl { attrs["privacyPolicyUrl"] = v }

        let body: [String: Any] = [
            "data": [
                "type": "betaAppLocalizations",
                "id": id,
                "attributes": attrs
            ]
        ]
        try await patch(path: "betaAppLocalizations/\(id)", body: body)
    }

    // MARK: - Beta Feedback

    func fetchBetaFeedback(buildId: String) async throws -> [ASCBetaFeedback] {
        let resp = try await get("betaFeedback", queryItems: [
            URLQueryItem(name: "filter[build]", value: buildId),
            URLQueryItem(name: "limit", value: "50")
        ], as: ASCListResponse<ASCBetaFeedback>.self)
        return resp.data
    }

    // MARK: - Write: Localization

    func patchLocalization(id: String, fields: [String: String]) async throws {
        let body: [String: Any] = [
            "data": [
                "type": "appStoreVersionLocalizations",
                "id": id,
                "attributes": fields
            ]
        ]
        try await patch(path: "appStoreVersionLocalizations/\(id)", body: body)
    }

    // MARK: - Write: AppInfoLocalization

    func patchAppInfoLocalization(id: String, privacyPolicyUrl: String) async throws {
        try await patchAppInfoLocalization(id: id, fields: ["privacyPolicyUrl": privacyPolicyUrl])
    }

    /// Patch appInfoLocalizations with arbitrary fields (name, subtitle, privacyPolicyUrl, etc.)
    func patchAppInfoLocalization(id: String, fields: [String: String]) async throws {
        let body: [String: Any] = [
            "data": [
                "type": "appInfoLocalizations",
                "id": id,
                "attributes": fields
            ] as [String: Any]
        ]
        try await patch(path: "appInfoLocalizations/\(id)", body: body)
    }

    // MARK: - Write: Version

    func createAppStoreVersion(
        appId: String,
        versionString: String,
        platform: String,
        copyright: String? = nil,
        releaseType: String? = nil
    ) async throws -> ASCAppStoreVersion {
        var attributes: [String: Any] = [
            "platform": platform,
            "versionString": versionString
        ]
        if let copyright, !copyright.isEmpty {
            attributes["copyright"] = copyright
        }
        if let releaseType, !releaseType.isEmpty {
            attributes["releaseType"] = releaseType
        }

        let body: [String: Any] = [
            "data": [
                "type": "appStoreVersions",
                "attributes": attributes,
                "relationships": [
                    "app": [
                        "data": [
                            "type": "apps",
                            "id": appId
                        ]
                    ]
                ]
            ] as [String: Any]
        ]

        let data = try await post(path: "appStoreVersions", body: body)
        return try JSONDecoder().decode(ASCSingleResponse<ASCAppStoreVersion>.self, from: data).data
    }

    func patchVersion(id: String, fields: [String: String]) async throws {
        let body: [String: Any] = [
            "data": [
                "type": "appStoreVersions",
                "id": id,
                "attributes": fields
            ]
        ]
        try await patch(path: "appStoreVersions/\(id)", body: body)
    }

    func createVersionLocalization(
        versionId: String,
        locale: String,
        fields: [String: String] = [:]
    ) async throws -> ASCVersionLocalization {
        var attributes = fields
        attributes["locale"] = locale

        let body: [String: Any] = [
            "data": [
                "type": "appStoreVersionLocalizations",
                "attributes": attributes,
                "relationships": [
                    "appStoreVersion": [
                        "data": [
                            "type": "appStoreVersions",
                            "id": versionId
                        ]
                    ]
                ]
            ] as [String: Any]
        ]

        let data = try await post(path: "appStoreVersionLocalizations", body: body)
        return try JSONDecoder().decode(ASCSingleResponse<ASCVersionLocalization>.self, from: data).data
    }

    /// Attach a build to an app store version (PATCH relationship)
    func attachBuild(versionId: String, buildId: String) async throws {
        let body: [String: Any] = [
            "data": [
                "type": "appStoreVersions",
                "id": versionId,
                "relationships": [
                    "build": [
                        "data": ["type": "builds", "id": buildId]
                    ]
                ]
            ] as [String: Any]
        ]
        try await patch(path: "appStoreVersions/\(versionId)", body: body)
    }

    // MARK: - Write: App

    func patchApp(id: String, fields: [String: String]) async throws {
        let body: [String: Any] = [
            "data": [
                "type": "apps",
                "id": id,
                "attributes": fields
            ]
        ]
        try await patch(path: "apps/\(id)", body: body)
    }

    // MARK: - Write: AppInfo

    /// Patch appInfos — only supports relationship fields (primaryCategory, subcategories, etc.)
    /// AppInfoUpdateRequest has NO attributes per the ASC OpenAPI spec.
    func patchAppInfo(id: String, fields: [String: String]) async throws {
        let categoryFields = ["primaryCategory", "primarySubcategoryOne", "primarySubcategoryTwo",
                              "secondaryCategory", "secondarySubcategoryOne", "secondarySubcategoryTwo"]
        var relationships: [String: Any] = [:]
        for field in categoryFields {
            if let value = fields[field] {
                relationships[field] = [
                    "data": ["type": "appCategories", "id": value]
                ] as [String: Any]
            }
        }
        guard !relationships.isEmpty else { return }
        let data: [String: Any] = [
            "type": "appInfos",
            "id": id,
            "relationships": relationships
        ]
        try await patch(path: "appInfos/\(id)", body: ["data": data])
    }

    // MARK: - Write: AgeRating

    func patchAgeRating(id: String, attributes: [String: Any]) async throws {
        let body: [String: Any] = [
            "data": [
                "type": "ageRatingDeclarations",
                "id": id,
                "attributes": attributes
            ]
        ]
        try await patch(path: "ageRatingDeclarations/\(id)", body: body)
    }

    // MARK: - Write: ReviewDetail

    func createOrPatchReviewDetail(versionId: String, attributes: [String: Any]) async throws -> ASCReviewDetail {
        let decodeResponse: (Data) throws -> ASCReviewDetail = { data in
            try JSONDecoder().decode(ASCSingleResponse<ASCReviewDetail>.self, from: data).data
        }

        do {
            let existing = try await fetchReviewDetail(versionId: versionId)
            // PATCH existing
            let body: [String: Any] = [
                "data": [
                    "type": "appStoreReviewDetails",
                    "id": existing.id,
                    "attributes": attributes
                ]
            ]
            let data = try await patchData(path: "appStoreReviewDetails/\(existing.id)", body: body)
            return try decodeResponse(data)
        } catch let error as ASCError {
            switch error {
            case .notFound, .httpError(404, _):
                let body: [String: Any] = [
                    "data": [
                        "type": "appStoreReviewDetails",
                        "attributes": attributes,
                        "relationships": [
                            "appStoreVersion": [
                                "data": ["type": "appStoreVersions", "id": versionId]
                            ]
                        ]
                    ]
                ]
                let data = try await post(path: "appStoreReviewDetails", body: body)
                return try decodeResponse(data)
            default:
                throw error
            }
        } catch {
            throw error
        }
    }

    // MARK: - Write: Pricing (Free)

    func setPriceFree(appId: String) async throws {
        // Fetch the FREE price point for USA territory
        let pricePoints = try await get("apps/\(appId)/appPricePoints", queryItems: [
            URLQueryItem(name: "filter[territory]", value: "USA"),
            URLQueryItem(name: "limit", value: "200")
        ], as: ASCListResponse<ASCPricePoint>.self)

        guard let freePoint = pricePoints.data.first(where: { $0.attributes.customerPrice == "0" || $0.attributes.customerPrice == "0.0" || $0.attributes.customerPrice == "0.00" }) else {
            throw ASCError.notFound("Free price point")
        }

        let body: [String: Any] = [
            "data": [
                "type": "appPriceSchedules",
                "relationships": [
                    "app": ["data": ["type": "apps", "id": appId]],
                    "baseTerritory": ["data": ["type": "territories", "id": "USA"]],
                    "manualPrices": ["data": [["type": "appPrices", "id": "${price0}"]]]
                ]
            ] as [String: Any],
            "included": [
                [
                    "type": "appPrices",
                    "id": "${price0}",
                    "relationships": [
                        "appPricePoint": ["data": ["type": "appPricePoints", "id": freePoint.id]]
                    ]
                ] as [String: Any]
            ]
        ]
        _ = try await post(path: "appPriceSchedules", body: body)
    }

    // MARK: - Write: Paid Pricing

    func fetchAppPricePoints(appId: String, territory: String = "USA") async throws -> [ASCPricePoint] {
        var all: [ASCPricePoint] = []
        var path = "apps/\(appId)/appPricePoints"
        var queryItems = [
            URLQueryItem(name: "filter[territory]", value: territory),
            URLQueryItem(name: "limit", value: "200")
        ]

        while true {
            let resp = try await get(path, queryItems: queryItems, as: ASCPaginatedResponse<ASCPricePoint>.self)
            all.append(contentsOf: resp.data)
            guard let next = resp.links?.next,
                  let comps = URLComponents(string: next),
                  !comps.path.isEmpty else { break }
            path = comps.path
            queryItems = comps.queryItems ?? []
        }
        return all
    }

    func fetchAppPricingState(appId: String, on referenceDate: Date = Date()) async throws -> ASCAppPricingState {
        let schedule = try await get(
            "apps/\(appId)/appPriceSchedule",
            as: ASCSingleResponse<ASCPriceSchedule>.self
        )
        // ASC returns 404 here when pricing has never been configured, which is
        // not an error state for Blitz. We still route the request through the
        // shared logger so 409s and malformed payloads are captured verbatim.
        let pricesResponse = try await performRequest(
            method: "GET",
            path: "appPriceSchedules/\(schedule.data.id)/manualPrices",
            queryItems: [
                URLQueryItem(name: "include", value: "appPricePoint"),
                URLQueryItem(name: "limit", value: "200")
            ],
            headers: ["Accept": "application/json"]
        )
        if pricesResponse.statusCode == 404 {
            return ASCAppPricingState(
                currentPricePointId: nil,
                scheduledPricePointId: nil,
                scheduledEffectiveDate: nil
            )
        }
        guard (200..<300).contains(pricesResponse.statusCode) else {
            let body = String(data: pricesResponse.body, encoding: .utf8) ?? ""
            throw ASCError.httpError(pricesResponse.statusCode, body)
        }
        let prices = try JSONDecoder().decode(ASCListResponse<ASCAppPrice>.self, from: pricesResponse.body)

        let today = Self.isoDateString(referenceDate)
        let sortedByStartDesc = prices.data.sorted { lhs, rhs in
            let lhsStart = lhs.startDate ?? ""
            let rhsStart = rhs.startDate ?? ""
            if lhsStart != rhsStart { return lhsStart > rhsStart }
            return lhs.id > rhs.id
        }

        let current = sortedByStartDesc.first(where: { Self.isActiveAppPrice($0, on: today) })
            ?? sortedByStartDesc.first(where: { $0.startDate == nil && $0.endDate == nil })

        let future = prices.data
            .filter {
                guard let startDate = $0.startDate else { return false }
                return startDate > today
            }
            .sorted { ($0.startDate ?? "") < ($1.startDate ?? "") }
            .first

        return ASCAppPricingState(
            currentPricePointId: current?.appPricePointId,
            scheduledPricePointId: future?.appPricePointId,
            scheduledEffectiveDate: future?.startDate
        )
    }

    func setAppPrice(appId: String, pricePointId: String) async throws {
        let body: [String: Any] = [
            "data": [
                "type": "appPriceSchedules",
                "relationships": [
                    "app": ["data": ["type": "apps", "id": appId]],
                    "baseTerritory": ["data": ["type": "territories", "id": "USA"]],
                    "manualPrices": ["data": [["type": "appPrices", "id": "${price0}"]]]
                ]
            ] as [String: Any],
            "included": [
                [
                    "type": "appPrices",
                    "id": "${price0}",
                    "relationships": [
                        "appPricePoint": ["data": ["type": "appPricePoints", "id": pricePointId]]
                    ]
                ] as [String: Any]
            ]
        ]
        _ = try await post(path: "appPriceSchedules", body: body)
    }

    // MARK: - In-App Purchases

    func createInAppPurchase(appId: String, name: String, productId: String, inAppPurchaseType: String, reviewNote: String? = nil) async throws -> ASCInAppPurchase {
        var attrs: [String: Any] = [
            "name": name,
            "productId": productId,
            "inAppPurchaseType": inAppPurchaseType
        ]
        if let reviewNote { attrs["reviewNote"] = reviewNote }

        let body: [String: Any] = [
            "data": [
                "type": "inAppPurchases",
                "attributes": attrs,
                "relationships": [
                    "app": ["data": ["type": "apps", "id": appId]]
                ]
            ] as [String: Any]
        ]
        let data = try await post(fullPath: "/v2/inAppPurchases", body: body)
        return try JSONDecoder().decode(ASCSingleResponse<ASCInAppPurchase>.self, from: data).data
    }

    func localizeInAppPurchase(iapId: String, locale: String, name: String, description: String?) async throws {
        var attrs: [String: Any] = [
            "name": name,
            "locale": locale
        ]
        if let description { attrs["description"] = description }

        let body: [String: Any] = [
            "data": [
                "type": "inAppPurchaseLocalizations",
                "attributes": attrs,
                "relationships": [
                    "inAppPurchaseV2": ["data": ["type": "inAppPurchases", "id": iapId]]
                ]
            ] as [String: Any]
        ]
        _ = try await post(path: "inAppPurchaseLocalizations", body: body)
    }

    func fetchInAppPurchasePricePoints(iapId: String, territory: String = "USA") async throws -> [ASCPricePoint] {
        let resp = try await get(fullPath: "/v2/inAppPurchases/\(iapId)/pricePoints", queryItems: [
            URLQueryItem(name: "filter[territory]", value: territory),
            URLQueryItem(name: "limit", value: "200")
        ], as: ASCListResponse<ASCPricePoint>.self)
        return resp.data
    }

    func setInAppPurchasePrice(iapId: String, pricePointId: String) async throws {
        let body: [String: Any] = [
            "data": [
                "type": "inAppPurchasePriceSchedules",
                "relationships": [
                    "inAppPurchase": ["data": ["type": "inAppPurchases", "id": iapId]],
                    "baseTerritory": ["data": ["type": "territories", "id": "USA"]],
                    "manualPrices": ["data": [["type": "inAppPurchasePrices", "id": "${price0}"]]]
                ]
            ] as [String: Any],
            "included": [
                [
                    "type": "inAppPurchasePrices",
                    "id": "${price0}",
                    "relationships": [
                        "inAppPurchasePricePoint": ["data": ["type": "inAppPurchasePricePoints", "id": pricePointId]]
                    ]
                ] as [String: Any]
            ]
        ]
        _ = try await post(path: "inAppPurchasePriceSchedules", body: body)
    }

    func fetchInAppPurchases(appId: String) async throws -> [ASCInAppPurchase] {
        var all: [ASCInAppPurchase] = []
        var path = "apps/\(appId)/inAppPurchasesV2"
        var queryItems = [URLQueryItem(name: "limit", value: "200")]

        while true {
            let resp = try await get(path, queryItems: queryItems, as: ASCPaginatedResponse<ASCInAppPurchase>.self)
            all.append(contentsOf: resp.data)
            guard let next = resp.links?.next,
                  let comps = URLComponents(string: next),
                  let nextPath = comps.path.split(separator: "/v1/").last else { break }
            path = String(nextPath)
            queryItems = comps.queryItems ?? []
        }
        return all
    }

    // MARK: - Territories & Availability

    func fetchAllTerritories() async throws -> [String] {
        var allIds: [String] = []
        var path = "territories"
        var queryItems = [URLQueryItem(name: "limit", value: "200")]

        while true {
            let resp = try await get(path, queryItems: queryItems, as: ASCPaginatedResponse<ASCTerritory>.self)
            allIds.append(contentsOf: resp.data.map(\.id))
            guard let next = resp.links?.next,
                  let comps = URLComponents(string: next),
                  let nextPath = comps.path.split(separator: "/v1/").last else { break }
            path = String(nextPath)
            queryItems = comps.queryItems ?? []
        }
        return allIds
    }

    func createIAPAvailability(iapId: String, territoryIds: [String]) async throws {
        let territoryData = territoryIds.map { ["type": "territories", "id": $0] }
        let body: [String: Any] = [
            "data": [
                "type": "inAppPurchaseAvailabilities",
                "attributes": ["availableInNewTerritories": true],
                "relationships": [
                    "inAppPurchase": ["data": ["type": "inAppPurchases", "id": iapId]],
                    "availableTerritories": ["data": territoryData]
                ]
            ] as [String: Any]
        ]
        _ = try await post(path: "inAppPurchaseAvailabilities", body: body)
    }

    /// Create app availability for all given territories using the v2 compound-document endpoint.
    /// POST /v2/appAvailabilities
    func createAppAvailability(appId: String, territoryIds: [String]) async throws {
        // Build inline-create entries for each territory
        var territoryRefs: [[String: Any]] = []
        var included: [[String: Any]] = []

        for (index, territoryId) in territoryIds.enumerated() {
            let tempId = "${ta\(index)}"
            territoryRefs.append(["type": "territoryAvailabilities", "id": tempId])
            included.append([
                "type": "territoryAvailabilities",
                "id": tempId,
                "attributes": ["available": true],
                "relationships": [
                    "territory": ["data": ["type": "territories", "id": territoryId]]
                ]
            ] as [String: Any])
        }

        let body: [String: Any] = [
            "data": [
                "type": "appAvailabilities",
                "attributes": ["availableInNewTerritories": true],
                "relationships": [
                    "app": ["data": ["type": "apps", "id": appId]],
                    "territoryAvailabilities": ["data": territoryRefs]
                ]
            ] as [String: Any],
            "included": included
        ]
        _ = try await post(fullPath: "/v2/appAvailabilities", body: body)
    }

    /// Ensure app availability is set for all territories. Silently succeeds if already configured (409).
    func ensureAppAvailability(appId: String) async throws {
        let territoryIds = try await fetchAllTerritories()
        do {
            try await createAppAvailability(appId: appId, territoryIds: territoryIds)
        } catch let ASCError.httpError(status, _) where status == 409 {
            // 409 Conflict means availability already exists — that's fine
        }
    }

    func createSubscriptionAvailability(subscriptionId: String, territoryIds: [String]) async throws {
        let territoryData = territoryIds.map { ["type": "territories", "id": $0] }
        let body: [String: Any] = [
            "data": [
                "type": "subscriptionAvailabilities",
                "attributes": ["availableInNewTerritories": true],
                "relationships": [
                    "subscription": ["data": ["type": "subscriptions", "id": subscriptionId]],
                    "availableTerritories": ["data": territoryData]
                ]
            ] as [String: Any]
        ]
        _ = try await post(path: "subscriptionAvailabilities", body: body)
    }

    // MARK: - Review Submissions

    func submitIAPForReview(iapId: String) async throws {
        let body: [String: Any] = [
            "data": [
                "type": "inAppPurchaseSubmissions",
                "relationships": [
                    "inAppPurchaseV2": ["data": ["type": "inAppPurchases", "id": iapId]]
                ]
            ] as [String: Any]
        ]
        _ = try await post(path: "inAppPurchaseSubmissions", body: body)
    }

    func submitSubscriptionForReview(subscriptionId: String) async throws {
        let body: [String: Any] = [
            "data": [
                "type": "subscriptionSubmissions",
                "relationships": [
                    "subscription": ["data": ["type": "subscriptions", "id": subscriptionId]]
                ]
            ] as [String: Any]
        ]
        _ = try await post(path: "subscriptionSubmissions", body: body)
    }

    // MARK: - Subscriptions

    func createSubscriptionGroup(appId: String, referenceName: String) async throws -> ASCSubscriptionGroup {
        let body: [String: Any] = [
            "data": [
                "type": "subscriptionGroups",
                "attributes": ["referenceName": referenceName],
                "relationships": [
                    "app": ["data": ["type": "apps", "id": appId]]
                ]
            ] as [String: Any]
        ]
        let data = try await post(path: "subscriptionGroups", body: body)
        return try JSONDecoder().decode(ASCSingleResponse<ASCSubscriptionGroup>.self, from: data).data
    }

    func localizeSubscriptionGroup(groupId: String, locale: String, name: String) async throws {
        let body: [String: Any] = [
            "data": [
                "type": "subscriptionGroupLocalizations",
                "attributes": ["name": name, "locale": locale],
                "relationships": [
                    "subscriptionGroup": ["data": ["type": "subscriptionGroups", "id": groupId]]
                ]
            ] as [String: Any]
        ]
        _ = try await post(path: "subscriptionGroupLocalizations", body: body)
    }

    func createSubscription(groupId: String, name: String, productId: String, subscriptionPeriod: String) async throws -> ASCSubscription {
        let body: [String: Any] = [
            "data": [
                "type": "subscriptions",
                "attributes": [
                    "name": name,
                    "productId": productId,
                    "subscriptionPeriod": subscriptionPeriod
                ],
                "relationships": [
                    "group": ["data": ["type": "subscriptionGroups", "id": groupId]]
                ]
            ] as [String: Any]
        ]
        let data = try await post(path: "subscriptions", body: body)
        return try JSONDecoder().decode(ASCSingleResponse<ASCSubscription>.self, from: data).data
    }

    func localizeSubscription(subscriptionId: String, locale: String, name: String, description: String?) async throws {
        var attrs: [String: Any] = [
            "name": name,
            "locale": locale
        ]
        if let description { attrs["description"] = description }

        let body: [String: Any] = [
            "data": [
                "type": "subscriptionLocalizations",
                "attributes": attrs,
                "relationships": [
                    "subscription": ["data": ["type": "subscriptions", "id": subscriptionId]]
                ]
            ] as [String: Any]
        ]
        _ = try await post(path: "subscriptionLocalizations", body: body)
    }

    func fetchSubscriptionPricePoints(subscriptionId: String, territory: String = "USA") async throws -> [ASCPricePoint] {
        let resp = try await get("subscriptions/\(subscriptionId)/pricePoints", queryItems: [
            URLQueryItem(name: "filter[territory]", value: territory),
            URLQueryItem(name: "limit", value: "200")
        ], as: ASCListResponse<ASCPricePoint>.self)
        return resp.data
    }

    func setSubscriptionPrice(subscriptionId: String, pricePointId: String, onProgress: (@Sendable (Int, Int) -> Void)? = nil) async throws {
        // Set base territory (USA) price
        try await postSubscriptionPrice(subscriptionId: subscriptionId, pricePointId: pricePointId)

        // Fetch Apple's auto-equalized prices for all other territories
        let equalizations = try await fetchSubscriptionPriceEqualizations(pricePointId: pricePointId)
        let total = equalizations.count

        // Set prices for all territories in parallel (10 concurrent)
        let counter = ProgressCounter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            let maxConcurrent = 10
            for (index, eq) in equalizations.enumerated() {
                if index >= maxConcurrent {
                    try await group.next()
                }
                group.addTask {
                    try await self.postSubscriptionPriceWithRetry(subscriptionId: subscriptionId, pricePointId: eq.id)
                    let done = await counter.increment()
                    onProgress?(done, total)
                }
            }
            try await group.waitForAll()
        }
    }

    private func postSubscriptionPriceWithRetry(subscriptionId: String, pricePointId: String, maxRetries: Int = 3) async throws {
        for attempt in 0..<maxRetries {
            do {
                try await postSubscriptionPrice(subscriptionId: subscriptionId, pricePointId: pricePointId)
                return
            } catch let error as ASCError {
                if case .httpError(let code, _) = error, (code == 429 || code >= 500) && attempt < maxRetries - 1 {
                    let delay = Double(attempt + 1) * 3.0
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                throw error
            }
        }
    }

    private func postSubscriptionPrice(subscriptionId: String, pricePointId: String) async throws {
        let body: [String: Any] = [
            "data": [
                "type": "subscriptionPrices",
                "attributes": ["preserveCurrentPrice": false, "startDate": NSNull()],
                "relationships": [
                    "subscription": ["data": ["type": "subscriptions", "id": subscriptionId]],
                    "subscriptionPricePoint": ["data": ["type": "subscriptionPricePoints", "id": pricePointId]]
                ]
            ] as [String: Any]
        ]
        _ = try await post(path: "subscriptionPrices", body: body)
    }

    private func fetchSubscriptionPriceEqualizations(pricePointId: String) async throws -> [ASCPricePoint] {
        var all: [ASCPricePoint] = []
        var path = "subscriptionPricePoints/\(pricePointId)/equalizations"
        var queryItems = [URLQueryItem(name: "limit", value: "200")]

        while true {
            let resp = try await get(path, queryItems: queryItems, as: ASCPaginatedResponse<ASCPricePoint>.self)
            all.append(contentsOf: resp.data)
            guard let next = resp.links?.next,
                  let comps = URLComponents(string: next),
                  let nextPath = comps.path.split(separator: "/v1/").last else { break }
            path = String(nextPath)
            queryItems = comps.queryItems ?? []
        }
        return all
    }

    func fetchSubscriptionGroups(appId: String) async throws -> [ASCSubscriptionGroup] {
        var all: [ASCSubscriptionGroup] = []
        var path = "apps/\(appId)/subscriptionGroups"
        var queryItems = [URLQueryItem(name: "limit", value: "200")]

        while true {
            let resp = try await get(path, queryItems: queryItems, as: ASCPaginatedResponse<ASCSubscriptionGroup>.self)
            all.append(contentsOf: resp.data)
            guard let next = resp.links?.next,
                  let comps = URLComponents(string: next),
                  let nextPath = comps.path.split(separator: "/v1/").last else { break }
            path = String(nextPath)
            queryItems = comps.queryItems ?? []
        }
        return all
    }

    func fetchSubscriptionsInGroup(groupId: String) async throws -> [ASCSubscription] {
        var all: [ASCSubscription] = []
        var path = "subscriptionGroups/\(groupId)/subscriptions"
        var queryItems = [URLQueryItem(name: "limit", value: "200")]

        while true {
            let resp = try await get(path, queryItems: queryItems, as: ASCPaginatedResponse<ASCSubscription>.self)
            all.append(contentsOf: resp.data)
            guard let next = resp.links?.next,
                  let comps = URLComponents(string: next),
                  let nextPath = comps.path.split(separator: "/v1/").last else { break }
            path = String(nextPath)
            queryItems = comps.queryItems ?? []
        }
        return all
    }

    func deleteInAppPurchase(iapId: String) async throws {
        try await delete(fullPath: "/v2/inAppPurchases/\(iapId)")
    }

    func deleteSubscription(subscriptionId: String) async throws {
        try await delete(path: "subscriptions/\(subscriptionId)")
    }

    func deleteSubscriptionGroup(groupId: String) async throws {
        try await delete(path: "subscriptionGroups/\(groupId)")
    }

    // MARK: - Scheduled Pricing

    /// Create a scheduled price change: current price until effectiveDate, then new price.
    func setScheduledAppPrice(appId: String, currentPricePointId: String, futurePricePointId: String, effectiveDate: String) async throws {
        let body: [String: Any] = [
            "data": [
                "type": "appPriceSchedules",
                "relationships": [
                    "app": ["data": ["type": "apps", "id": appId]],
                    "baseTerritory": ["data": ["type": "territories", "id": "USA"]],
                    "manualPrices": ["data": [
                        ["type": "appPrices", "id": "${base}"],
                        ["type": "appPrices", "id": "${future}"]
                    ]]
                ]
            ] as [String: Any],
            "included": [
                [
                    "type": "appPrices",
                    "id": "${base}",
                    "attributes": ["endDate": effectiveDate],
                    "relationships": [
                        "appPricePoint": ["data": ["type": "appPricePoints", "id": currentPricePointId]]
                    ]
                ] as [String: Any],
                [
                    "type": "appPrices",
                    "id": "${future}",
                    "attributes": ["startDate": effectiveDate],
                    "relationships": [
                        "appPricePoint": ["data": ["type": "appPricePoints", "id": futurePricePointId]]
                    ]
                ] as [String: Any]
            ]
        ]
        _ = try await post(path: "appPriceSchedules", body: body)
    }

    // MARK: - IAP Editing

    func patchInAppPurchase(iapId: String, attrs: [String: Any]) async throws {
        let body: [String: Any] = [
            "data": [
                "type": "inAppPurchases",
                "id": iapId,
                "attributes": attrs
            ]
        ]
        try await patch(fullPath: "/v2/inAppPurchases/\(iapId)", body: body)
    }

    func fetchIAPLocalizations(iapId: String) async throws -> [ASCIAPLocalization] {
        let resp = try await get(fullPath: "/v2/inAppPurchases/\(iapId)/inAppPurchaseLocalizations",
                                 as: ASCListResponse<ASCIAPLocalization>.self)
        return resp.data
    }

    func patchIAPLocalization(locId: String, fields: [String: String]) async throws {
        let body: [String: Any] = [
            "data": [
                "type": "inAppPurchaseLocalizations",
                "id": locId,
                "attributes": fields
            ]
        ]
        try await patch(path: "inAppPurchaseLocalizations/\(locId)", body: body)
    }

    // MARK: - Subscription Editing

    func patchSubscription(subscriptionId: String, attrs: [String: Any]) async throws {
        let body: [String: Any] = [
            "data": [
                "type": "subscriptions",
                "id": subscriptionId,
                "attributes": attrs
            ]
        ]
        try await patch(path: "subscriptions/\(subscriptionId)", body: body)
    }

    func fetchSubscriptionLocalizations(subscriptionId: String) async throws -> [ASCSubscriptionLocalization] {
        let resp = try await get("subscriptions/\(subscriptionId)/subscriptionLocalizations",
                                 as: ASCListResponse<ASCSubscriptionLocalization>.self)
        return resp.data
    }

    func patchSubscriptionLocalization(locId: String, fields: [String: String]) async throws {
        let body: [String: Any] = [
            "data": [
                "type": "subscriptionLocalizations",
                "id": locId,
                "attributes": fields
            ]
        ]
        try await patch(path: "subscriptionLocalizations/\(locId)", body: body)
    }

    // MARK: - Subscription Group Localization

    func fetchSubscriptionGroupLocalizations(groupId: String) async throws -> [ASCSubscriptionGroupLocalization] {
        let resp = try await get("subscriptionGroups/\(groupId)/subscriptionGroupLocalizations",
                                 as: ASCListResponse<ASCSubscriptionGroupLocalization>.self)
        return resp.data
    }

    func patchSubscriptionGroupLocalization(locId: String, name: String) async throws {
        let body: [String: Any] = [
            "data": [
                "type": "subscriptionGroupLocalizations",
                "id": locId,
                "attributes": ["name": name]
            ]
        ]
        try await patch(path: "subscriptionGroupLocalizations/\(locId)", body: body)
    }

    // MARK: - IAP Review Screenshot

    func uploadIAPReviewScreenshot(iapId: String, path: String) async throws {
        let fileURL = URL(fileURLWithPath: path)
        let fileData = try Data(contentsOf: fileURL)
        let fileName = fileURL.lastPathComponent

        // Reserve
        let reserveBody: [String: Any] = [
            "data": [
                "type": "inAppPurchaseAppStoreReviewScreenshots",
                "attributes": ["fileName": fileName, "fileSize": fileData.count],
                "relationships": [
                    "inAppPurchaseV2": ["data": ["type": "inAppPurchases", "id": iapId]]
                ]
            ] as [String: Any]
        ]
        let reserveData = try await post(path: "inAppPurchaseAppStoreReviewScreenshots", body: reserveBody)
        let reserved = try JSONDecoder().decode(ASCSingleResponse<ASCScreenshotReservation>.self, from: reserveData)
        let screenshotId = reserved.data.id

        // Upload chunks
        for op in reserved.data.attributes.uploadOperations ?? [] {
            guard let uploadURL = URL(string: op.url) else { continue }
            let chunk = fileData[op.offset..<min(op.offset + op.length, fileData.count)]
            var headers = [String: String]()
            for header in op.requestHeaders { headers[header.name] = header.value }
            try await upload(url: uploadURL, method: op.method, headers: headers, body: Data(chunk))
        }

        // Commit
        let commitBody: [String: Any] = [
            "data": [
                "type": "inAppPurchaseAppStoreReviewScreenshots",
                "id": screenshotId,
                "attributes": ["uploaded": true, "sourceFileChecksum": reserved.data.attributes.sourceFileChecksum ?? ""]
            ]
        ]
        try await patch(path: "inAppPurchaseAppStoreReviewScreenshots/\(screenshotId)", body: commitBody)
    }

    // MARK: - Subscription Review Screenshot

    func uploadSubscriptionReviewScreenshot(subscriptionId: String, path: String) async throws {
        let fileURL = URL(fileURLWithPath: path)
        let fileData = try Data(contentsOf: fileURL)
        let fileName = fileURL.lastPathComponent

        // Reserve
        let reserveBody: [String: Any] = [
            "data": [
                "type": "subscriptionAppStoreReviewScreenshots",
                "attributes": ["fileName": fileName, "fileSize": fileData.count],
                "relationships": [
                    "subscription": ["data": ["type": "subscriptions", "id": subscriptionId]]
                ]
            ] as [String: Any]
        ]
        let reserveData = try await post(path: "subscriptionAppStoreReviewScreenshots", body: reserveBody)
        let reserved = try JSONDecoder().decode(ASCSingleResponse<ASCScreenshotReservation>.self, from: reserveData)
        let screenshotId = reserved.data.id

        // Upload chunks
        for op in reserved.data.attributes.uploadOperations ?? [] {
            guard let uploadURL = URL(string: op.url) else { continue }
            let chunk = fileData[op.offset..<min(op.offset + op.length, fileData.count)]
            var headers = [String: String]()
            for header in op.requestHeaders { headers[header.name] = header.value }
            try await upload(url: uploadURL, method: op.method, headers: headers, body: Data(chunk))
        }

        // Commit
        let commitBody: [String: Any] = [
            "data": [
                "type": "subscriptionAppStoreReviewScreenshots",
                "id": screenshotId,
                "attributes": ["uploaded": true, "sourceFileChecksum": reserved.data.attributes.sourceFileChecksum ?? ""]
            ]
        ]
        try await patch(path: "subscriptionAppStoreReviewScreenshots/\(screenshotId)", body: commitBody)
    }

    // MARK: - Write: Screenshot Upload

    func uploadScreenshot(localizationId: String, path: String, displayType: String) async throws {
        // Step 1: Ensure screenshot set exists
        let sets = try await fetchScreenshotSets(localizationId: localizationId)
        let setId: String
        if let existing = sets.first(where: { $0.attributes.screenshotDisplayType == displayType }) {
            setId = existing.id
        } else {
            let createBody: [String: Any] = [
                "data": [
                    "type": "appScreenshotSets",
                    "attributes": ["screenshotDisplayType": displayType],
                    "relationships": [
                        "appStoreVersionLocalization": [
                            "data": ["type": "appStoreVersionLocalizations", "id": localizationId]
                        ]
                    ]
                ]
            ]
            let data = try await post(path: "appScreenshotSets", body: createBody)
            let created = try JSONDecoder().decode(ASCSingleResponse<ASCScreenshotSet>.self, from: data)
            setId = created.data.id
        }

        // Step 2: Reserve the screenshot
        let fileURL = URL(fileURLWithPath: path)
        let fileData = try Data(contentsOf: fileURL)
        let fileName = fileURL.lastPathComponent
        let reserveBody: [String: Any] = [
            "data": [
                "type": "appScreenshots",
                "attributes": [
                    "fileName": fileName,
                    "fileSize": fileData.count
                ],
                "relationships": [
                    "appScreenshotSet": [
                        "data": ["type": "appScreenshotSets", "id": setId]
                    ]
                ]
            ]
        ]
        let reserveData = try await post(path: "appScreenshots", body: reserveBody)
        let reserved = try JSONDecoder().decode(ASCSingleResponse<ASCScreenshotReservation>.self, from: reserveData)
        let screenshotId = reserved.data.id

        // Step 3: Upload to the provided upload operations
        for op in reserved.data.attributes.uploadOperations ?? [] {
            guard let uploadURL = URL(string: op.url) else { continue }
            let offset = op.offset
            let length = op.length
            let chunk = fileData[offset..<min(offset + length, fileData.count)]
            var headers = [String: String]()
            for header in op.requestHeaders {
                headers[header.name] = header.value
            }
            try await upload(url: uploadURL, method: op.method, headers: headers, body: Data(chunk))
        }

        // Step 4: Commit the upload
        let commitBody: [String: Any] = [
            "data": [
                "type": "appScreenshots",
                "id": screenshotId,
                "attributes": [
                    "uploaded": true,
                    "sourceFileChecksum": reserved.data.attributes.sourceFileChecksum ?? ""
                ]
            ]
        ]
        try await patch(path: "appScreenshots/\(screenshotId)", body: commitBody)
    }

    // MARK: - Write: Build Encryption

    func patchBuildEncryption(buildId: String, usesNonExemptEncryption: Bool) async throws {
        let requestBody: [String: Any] = [
            "data": [
                "type": "builds",
                "id": buildId,
                "attributes": [
                    "usesNonExemptEncryption": usesNonExemptEncryption
                ]
            ]
        ]
        let response = try await client.request(
            method: "PATCH",
            path: try resolvedPath("builds/\(buildId)"),
            headers: [
                "Accept": "application/json",
                "Content-Type": "application/json",
            ],
            body: try JSONSerialization.data(withJSONObject: requestBody),
            expectedStatusCodes: [409]
        )
        if (200..<300).contains(response.statusCode) {
            return
        }
        if response.statusCode == 409 {
            let responseBody = String(data: response.body, encoding: .utf8) ?? ""
            if responseBody.contains("You cannot update when the value is already set.")
                || responseBody.contains("/data/attributes/usesNonExemptEncryption") {
                return
            }
            throw ASCError.httpError(response.statusCode, responseBody)
        }
        let responseBody = String(data: response.body, encoding: .utf8) ?? ""
        throw ASCError.httpError(response.statusCode, responseBody)
    }

    // MARK: - Fetch: AppInfo

    func fetchAppInfo(appId: String) async throws -> ASCAppInfo {
        // include=primaryCategory so the relationship data (with category ID) is populated
        let resp = try await get("apps/\(appId)/appInfos", queryItems: [
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "include", value: "primaryCategory")
        ], as: ASCListResponse<ASCAppInfo>.self)
        guard let info = resp.data.first else {
            throw ASCError.notFound("AppInfo for app \(appId)")
        }
        return info
    }

    // MARK: - Fetch: AgeRating

    func fetchAgeRating(appInfoId: String) async throws -> ASCAgeRatingDeclaration {
        let resp = try await get(
            "appInfos/\(appInfoId)/ageRatingDeclaration",
            as: ASCSingleResponse<ASCAgeRatingDeclaration>.self
        )
        return resp.data
    }

    // MARK: - Fetch: ReviewDetail

    func fetchReviewDetail(versionId: String) async throws -> ASCReviewDetail {
        let response = try await performRequest(
            method: "GET",
            path: "appStoreVersions/\(versionId)/appStoreReviewDetail",
            headers: ["Accept": "application/json"]
        )
        if response.statusCode == 404 {
            throw ASCError.notFound("Review detail for version \(versionId)")
        }
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: response.body, encoding: .utf8) ?? ""
            throw ASCError.httpError(response.statusCode, body)
        }
        guard !response.body.isEmpty,
              let decoded = try? JSONDecoder().decode(ASCSingleResponse<ASCReviewDetail>.self, from: response.body),
              !decoded.data.isPlaceholder else {
            throw ASCError.notFound("Review detail for version \(versionId)")
        }
        return decoded.data
    }

    // MARK: - Fetch: AppInfoLocalization

    func fetchAppInfoLocalizations(appInfoId: String) async throws -> [ASCAppInfoLocalization] {
        let resp = try await get(
            "appInfos/\(appInfoId)/appInfoLocalizations",
            queryItems: [URLQueryItem(name: "limit", value: "200")],
            as: ASCListResponse<ASCAppInfoLocalization>.self
        )
        return resp.data
    }

    func fetchAppInfoLocalization(appInfoId: String) async throws -> ASCAppInfoLocalization {
        let localizations = try await fetchAppInfoLocalizations(appInfoId: appInfoId)
        guard let loc = localizations.first else {
            throw ASCError.notFound("AppInfoLocalization for appInfo \(appInfoId)")
        }
        return loc
    }

    func createAppInfoLocalization(
        appInfoId: String,
        locale: String,
        fields: [String: String] = [:]
    ) async throws -> ASCAppInfoLocalization {
        var attributes = fields
        attributes["locale"] = locale

        let body: [String: Any] = [
            "data": [
                "type": "appInfoLocalizations",
                "attributes": attributes,
                "relationships": [
                    "appInfo": [
                        "data": [
                            "type": "appInfos",
                            "id": appInfoId
                        ]
                    ]
                ]
            ]
        ]

        let data = try await post(path: "appInfoLocalizations", body: body)
        return try JSONDecoder().decode(ASCSingleResponse<ASCAppInfoLocalization>.self, from: data).data
    }

    // MARK: - Pricing Check

    /// Check if pricing has been configured for an app.
    /// Fetches the price schedule and checks for manual prices.
    func fetchPricingConfigured(appId: String) async -> Bool {
        (try? await fetchPricingConfiguredDetailed(appId: appId)) ?? false
    }

    func fetchPricingConfiguredDetailed(appId: String) async throws -> Bool {
        let schedule = try await get(
            "apps/\(appId)/appPriceSchedule",
            as: ASCSingleResponse<ASCPriceSchedule>.self
        )
        let pricesResponse = try await performRequest(
            method: "GET",
            path: "appPriceSchedules/\(schedule.data.id)/manualPrices",
            queryItems: [URLQueryItem(name: "limit", value: "1")],
            headers: ["Accept": "application/json"]
        )
        if pricesResponse.statusCode == 404 {
            return false
        }
        guard (200..<300).contains(pricesResponse.statusCode) else {
            let body = String(data: pricesResponse.body, encoding: .utf8) ?? ""
            throw ASCError.httpError(pricesResponse.statusCode, body)
        }
        let prices = try JSONDecoder().decode(ASCListResponse<ASCPriceScheduleEntry>.self, from: pricesResponse.body)
        return !prices.data.isEmpty
    }

    private static func isoDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func isActiveAppPrice(_ price: ASCAppPrice, on date: String) -> Bool {
        if let startDate = price.startDate, startDate > date {
            return false
        }
        if let endDate = price.endDate, endDate < date {
            return false
        }
        return true
    }

    // MARK: - Bundle IDs

    func fetchBundleId(identifier: String) async throws -> ASCBundleId? {
        let resp = try await get("bundleIds", queryItems: [
            URLQueryItem(name: "filter[identifier]", value: identifier),
            URLQueryItem(name: "limit", value: "1")
        ], as: ASCListResponse<ASCBundleId>.self)
        return resp.data.first
    }

    func registerBundleId(identifier: String, name: String, platform: String = "IOS") async throws -> ASCBundleId {
        let body: [String: Any] = [
            "data": [
                "type": "bundleIds",
                "attributes": [
                    "identifier": identifier,
                    "name": name,
                    "platform": platform
                ]
            ]
        ]
        let data = try await post(path: "bundleIds", body: body)
        let result = try JSONDecoder().decode(ASCSingleResponse<ASCBundleId>.self, from: data)
        return result.data
    }

    // MARK: - Certificates

    func fetchDistributionCertificates() async throws -> [ASCCertificate] {
        let resp = try await get("certificates", queryItems: [
            URLQueryItem(name: "filter[certificateType]", value: "DISTRIBUTION"),
            URLQueryItem(name: "limit", value: "50")
        ], as: ASCListResponse<ASCCertificate>.self)
        return resp.data
    }

    func fetchCertificates(type: String) async throws -> [ASCCertificate] {
        let resp = try await get("certificates", queryItems: [
            URLQueryItem(name: "filter[certificateType]", value: type),
            URLQueryItem(name: "limit", value: "50")
        ], as: ASCListResponse<ASCCertificate>.self)
        return resp.data
    }

    func createCertificate(csrContent: String, type: String = "DISTRIBUTION") async throws -> ASCCertificate {
        let body: [String: Any] = [
            "data": [
                "type": "certificates",
                "attributes": [
                    "certificateType": type,
                    "csrContent": csrContent
                ]
            ]
        ]
        let data = try await post(path: "certificates", body: body)
        let result = try JSONDecoder().decode(ASCSingleResponse<ASCCertificate>.self, from: data)
        return result.data
    }

    // MARK: - Profiles

    func createProfile(name: String, bundleIdResourceId: String, certificateId: String, profileType: String = "IOS_APP_STORE") async throws -> ASCProfile {
        let body: [String: Any] = [
            "data": [
                "type": "profiles",
                "attributes": [
                    "name": name,
                    "profileType": profileType
                ],
                "relationships": [
                    "bundleId": [
                        "data": ["type": "bundleIds", "id": bundleIdResourceId]
                    ],
                    "certificates": [
                        "data": [["type": "certificates", "id": certificateId]]
                    ]
                ]
            ]
        ]
        let data = try await post(path: "profiles", body: body)
        let result = try JSONDecoder().decode(ASCSingleResponse<ASCProfile>.self, from: data)
        return result.data
    }

    func fetchProfiles(name: String) async throws -> [ASCProfile] {
        let resp = try await get("profiles", queryItems: [
            URLQueryItem(name: "filter[name]", value: name),
            URLQueryItem(name: "limit", value: "10")
        ], as: ASCListResponse<ASCProfile>.self)
        return resp.data
    }

    func deleteProfile(id: String) async throws {
        try await delete(path: "profiles/\(id)")
    }

    // MARK: - Bundle ID Capabilities

    func enableCapability(bundleIdResourceId: String, capabilityType: String) async throws {
        let body: [String: Any] = [
            "data": [
                "type": "bundleIdCapabilities",
                "attributes": [
                    "capabilityType": capabilityType
                ],
                "relationships": [
                    "bundleId": [
                        "data": ["type": "bundleIds", "id": bundleIdResourceId]
                    ]
                ]
            ] as [String: Any]
        ]
        _ = try await post(path: "bundleIdCapabilities", body: body)
    }

    // MARK: - Build Polling

    func fetchLatestBuild(appId: String) async throws -> ASCBuild? {
        let resp = try await get("builds", queryItems: [
            URLQueryItem(name: "filter[app]", value: appId),
            URLQueryItem(name: "sort", value: "-uploadedDate"),
            URLQueryItem(name: "limit", value: "1")
        ], as: ASCListResponse<ASCBuild>.self)
        return resp.data.first
    }

    func fetchBuildAttachedToVersion(versionId: String) async throws -> ASCBuild? {
        do {
            let resp = try await get(
                "appStoreVersions/\(versionId)/build",
                as: ASCSingleResponse<ASCBuild>.self
            )
            return resp.data
        } catch let ASCError.httpError(code, _) where code == 404 {
            return nil
        }
    }

    // MARK: - Fetch Review Submissions

    func fetchReviewSubmissions(appId: String) async throws -> [ASCReviewSubmission] {
        let resp = try await get("reviewSubmissions", queryItems: [
            URLQueryItem(name: "filter[app]", value: appId),
            URLQueryItem(name: "limit", value: "10")
        ], as: ASCPaginatedResponse<ASCReviewSubmission>.self)
        return sortReviewSubmissions(resp.data)
    }

    func fetchReviewSubmissionItems(submissionId: String) async throws -> [ASCReviewSubmissionItem] {
        let resp = try await get("reviewSubmissions/\(submissionId)/items", queryItems: [
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "include", value: "appStoreVersion"),
        ], as: ASCPaginatedResponse<ASCReviewSubmissionItem>.self)
        return resp.data
    }

    private func sortReviewSubmissions(_ submissions: [ASCReviewSubmission]) -> [ASCReviewSubmission] {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let standardFormatter = ISO8601DateFormatter()
        standardFormatter.formatOptions = [.withInternetDateTime]

        return submissions
            .enumerated()
            .sorted { lhs, rhs in
                let lhsDate = reviewSubmissionDate(
                    lhs.element.attributes.submittedDate,
                    fractionalFormatter: fractionalFormatter,
                    standardFormatter: standardFormatter
                )
                let rhsDate = reviewSubmissionDate(
                    rhs.element.attributes.submittedDate,
                    fractionalFormatter: fractionalFormatter,
                    standardFormatter: standardFormatter
                )

                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func reviewSubmissionDate(
        _ value: String?,
        fractionalFormatter: ISO8601DateFormatter,
        standardFormatter: ISO8601DateFormatter
    ) -> Date {
        guard let value, !value.isEmpty else { return .distantPast }
        return fractionalFormatter.date(from: value)
            ?? standardFormatter.date(from: value)
            ?? .distantPast
    }

    // MARK: - Submit for Review

    func submitForReview(appId: String, versionId: String) async throws {
        // Step 1: Create review submission
        let submissionBody: [String: Any] = [
            "data": [
                "type": "reviewSubmissions",
                "relationships": [
                    "app": ["data": ["type": "apps", "id": appId]]
                ]
            ]
        ]
        let submissionData = try await post(path: "reviewSubmissions", body: submissionBody)
        let submission = try JSONDecoder().decode(ASCSingleResponse<ASCReviewSubmission>.self, from: submissionData)
        let submissionId = submission.data.id

        // Step 2: Add submission item (the version)
        let itemBody: [String: Any] = [
            "data": [
                "type": "reviewSubmissionItems",
                "relationships": [
                    "reviewSubmission": ["data": ["type": "reviewSubmissions", "id": submissionId]],
                    "appStoreVersion": ["data": ["type": "appStoreVersions", "id": versionId]]
                ]
            ]
        ]
        _ = try await post(path: "reviewSubmissionItems", body: itemBody)

        // Step 3: Confirm submission
        let confirmBody: [String: Any] = [
            "data": [
                "type": "reviewSubmissions",
                "id": submissionId,
                "attributes": ["submitted": true]
            ]
        ]
        try await patch(path: "reviewSubmissions/\(submissionId)", body: confirmBody)
    }
}

// MARK: - Supporting Types

private actor ProgressCounter {
    private var count = 0
    func increment() -> Int {
        count += 1
        return count
    }
}

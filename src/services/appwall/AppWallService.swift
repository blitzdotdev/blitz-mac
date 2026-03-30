import Foundation
import CryptoKit

// MARK: - Data+Base64URL

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - AppWallService

actor AppWallService {
    static let shared = AppWallService()

    private let wallBaseURL = "https://appwall.blitzmen.workers.dev"
    private let session = URLSession.shared

    struct SyncFailure: Sendable {
        let bundleId: String
        let reason: String
    }

    struct SyncResult: Sendable {
        let successfulBundleIds: Set<String>
        let failures: [SyncFailure]

        var successCount: Int { successfulBundleIds.count }
    }

    // MARK: - JWT Generation

    func generateASCJWT(credentials: ASCCredentials) throws -> String {
        let now = Int(Date().timeIntervalSince1970)

        let headerData = try JSONSerialization.data(withJSONObject: [
            "alg": "ES256",
            "kid": credentials.keyId,
            "typ": "JWT"
        ] as [String: String], options: [.sortedKeys])

        let payloadData = try JSONSerialization.data(withJSONObject: [
            "iss": credentials.issuerId,
            "iat": now,
            "exp": now + 1200,
            "aud": "appstoreconnect-v1"
        ] as [String: Any])

        let headerB64 = headerData.base64URLEncoded()
        let payloadB64 = payloadData.base64URLEncoded()
        let signingInput = "\(headerB64).\(payloadB64)"

        guard let signingData = signingInput.data(using: .utf8) else {
            throw AppWallError.jwtGenerationFailed
        }

        let privateKey = try P256.Signing.PrivateKey(pemRepresentation: credentials.privateKey)
        let signature = try privateKey.signature(for: signingData)
        return "\(signingInput).\(signature.rawRepresentation.base64URLEncoded())"
    }

    // MARK: - Credential Validation

    func validateCredentials(_ credentials: ASCCredentials) async throws -> Bool {
        let jwt = try generateASCJWT(credentials: credentials)
        guard let url = URL(string: "https://api.appstoreconnect.apple.com/v1/apps?limit=1") else {
            throw AppWallError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    // MARK: - iTunes Metadata (batch icon + category lookup)

    struct ITunesMeta {
        let iconUrl: String?
        let category: String?
    }

    /// Fetches icon URLs and primary category for a batch of apps via the iTunes Lookup API.
    /// Uses the Apple numeric app ID (same as ASC asc_app_id) — one network call for all apps.
    func fetchITunesMeta(appleIds: [String]) async -> [String: ITunesMeta] {
        guard !appleIds.isEmpty else { return [:] }
        let ids = appleIds.joined(separator: ",")
        guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(ids)") else { return [:] }

        struct Response: Decodable {
            let results: [Result]
            struct Result: Decodable {
                let trackId: Int?
                let artworkUrl512: String?
                let primaryGenreName: String?
            }
        }

        guard let (data, _) = try? await session.data(for: URLRequest(url: url)),
              let resp = try? JSONDecoder().decode(Response.self, from: data) else { return [:] }

        return Dictionary(uniqueKeysWithValues: resp.results.compactMap { r -> (String, ITunesMeta)? in
            guard let trackId = r.trackId else { return nil }
            return (String(trackId), ITunesMeta(iconUrl: r.artworkUrl512, category: r.primaryGenreName))
        })
    }

    // MARK: - Sync

    /// Pushes apps to the App Wall. Fetches icons/categories from iTunes in a single batch call first.
    /// Apps without version data are treated as failures and skipped so the wall
    /// does not regress app summaries back to stale/null state.
    func syncApps(
        credentials: ASCCredentials,
        syncData: [AppWallSyncData]
    ) async throws -> SyncResult {
        let jwt = try generateASCJWT(credentials: credentials)

        // One iTunes call for all apps to get icon URLs and categories
        let itunesMeta = await fetchITunesMeta(appleIds: syncData.map(\.ascApp.id))
        Log("[AppWall] iTunes meta fetched for \(itunesMeta.count)/\(syncData.count) apps")

        var successfulBundleIds = Set<String>()
        var failures: [SyncFailure] = []
        for syncData in syncData {
            let ascApp = syncData.ascApp
            guard let url = URL(string: "\(wallBaseURL)/api/v1/push") else {
                failures.append(SyncFailure(bundleId: ascApp.bundleId, reason: "Invalid App Wall URL"))
                continue
            }

            let versions = syncData.versions
            guard let latestVersion = versions.first else {
                let reason = "No App Store versions were returned for this app"
                Log("[AppWall] skip \(ascApp.bundleId) — \(reason)")
                failures.append(SyncFailure(bundleId: ascApp.bundleId, reason: reason))
                continue
            }
            let currentWallVersion = ASCReleaseStatus.appWallCurrentVersion(for: versions) ?? latestVersion

            var appPayload: [String: Any] = [
                "asc_app_id": ascApp.id,
                "bundle_id": ascApp.bundleId,
                "name": ascApp.name,
                "is_on_wall": true
            ]
            if let locale = ascApp.primaryLocale { appPayload["primary_locale"] = locale }
            if let meta = itunesMeta[ascApp.id] {
                if let icon = meta.iconUrl { appPayload["icon_url"] = icon }
                if let cat = meta.category { appPayload["primary_category"] = cat }
            }
            appPayload["latest_version"] = currentWallVersion.attributes.versionString
            // The app-wall card shows one summary state. Use the derived
            // dashboard-style status so a newer draft update does not mask a
            // currently live release as "Prepare for Submission".
            if let state = ASCReleaseStatus.appWallCurrentState(for: versions) {
                appPayload["current_state"] = state
            }

            let versionsPayload: [[String: Any]] = versions.map { ver in
                var v: [String: Any] = [
                    "asc_version_id": ver.id,
                    "version_string": ver.attributes.versionString,
                ]
                if let state = ver.attributes.appStoreState { v["state"] = state }
                return v
            }
            let eventsPayload = syncData.events.map(\.jsonObject)
            let feedbacksPayload = syncData.feedbacks.map(\.jsonObject)

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let requestBody: [String: Any] = [
                "asc_jwt": jwt,
                "app": appPayload,
                "versions": versionsPayload,
                "events": eventsPayload,
                "feedbacks": feedbacksPayload,
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
            request.timeoutInterval = 30

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    Log("[AppWall] push \(ascApp.bundleId) — no HTTP response")
                    failures.append(SyncFailure(bundleId: ascApp.bundleId, reason: "No HTTP response from App Wall"))
                    continue
                }
                let body = String(data: data, encoding: .utf8) ?? ""
                Log("[AppWall] push \(ascApp.bundleId) ← \(http.statusCode): \(body.prefix(200))")
                if (200..<300).contains(http.statusCode) {
                    successfulBundleIds.insert(ascApp.bundleId)
                } else {
                    failures.append(SyncFailure(
                        bundleId: ascApp.bundleId,
                        reason: condensedFailureReason(statusCode: http.statusCode, body: body)
                    ))
                }
            } catch {
                Log("[AppWall] push \(ascApp.bundleId) — request failed: \(error.localizedDescription)")
                failures.append(SyncFailure(bundleId: ascApp.bundleId, reason: error.localizedDescription))
            }
        }

        return SyncResult(successfulBundleIds: successfulBundleIds, failures: failures)
    }

    // MARK: - Fetch Wall Apps

    func fetchWallApps(limit: Int = 50, offset: Int = 0) async throws -> AppWallListResponse<AppWallApp> {
        return try await wallList("apps", body: ["limit": limit, "offset": offset, "order": "-updated"])
    }

    func fetchVersions(appId: String) async throws -> [AppWallVersion] {
        let resp: AppWallListResponse<AppWallVersion> = try await wallList(
            "app_versions",
            body: ["where": "app_id == '\(appId)'", "order": "-updated", "limit": 50]
        )
        return resp.items
    }

    func fetchEvents(appId: String) async throws -> [AppWallEvent] {
        let resp: AppWallListResponse<AppWallEvent> = try await wallList(
            "submission_events",
            body: ["where": "app_id == '\(appId)'", "order": "-occurred_at", "limit": 200]
        )
        return resp.items
    }

    func fetchFeedbacks(appId: String) async throws -> [AppWallFeedback] {
        let resp: AppWallListResponse<AppWallFeedback> = try await wallList(
            "reviewer_feedbacks",
            body: ["where": "app_id == '\(appId)'", "order": "-occurred_at", "limit": 50]
        )
        return resp.items
    }

    // MARK: - Private helpers

    private func wallList<T: Decodable>(_ table: String, body: [String: Any]) async throws -> AppWallListResponse<T> {
        let urlString = "\(wallBaseURL)/api/v1/table/\(table)/list"
        guard let url = URL(string: urlString) else { throw AppWallError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        let bodyStr = String(data: data, encoding: .utf8) ?? ""
        guard let http = response as? HTTPURLResponse else {
            throw AppWallError.fetchFailed("\(table): no HTTP response")
        }
        Log("[AppWall] \(table)/list ← \(http.statusCode): \(bodyStr.prefix(300))")
        guard (200..<300).contains(http.statusCode) else {
            throw AppWallError.fetchFailed("HTTP \(http.statusCode): \(bodyStr)")
        }
        return try JSONDecoder().decode(AppWallListResponse<T>.self, from: data)
    }

    private func condensedFailureReason(statusCode: Int, body: String) -> String {
        let trimmedBody = body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else {
            return "HTTP \(statusCode)"
        }

        let message = trimmedBody.count > 180 ? String(trimmedBody.prefix(180)) + "..." : trimmedBody
        return "HTTP \(statusCode): \(message)"
    }
}

// MARK: - AppWallError

enum AppWallError: LocalizedError {
    case jwtGenerationFailed
    case invalidURL
    case fetchFailed(String)

    var errorDescription: String? {
        switch self {
        case .jwtGenerationFailed: "Failed to generate ASC developer token"
        case .invalidURL: "Invalid URL"
        case .fetchFailed(let detail): "Failed to fetch from App Wall: \(detail)"
        }
    }
}

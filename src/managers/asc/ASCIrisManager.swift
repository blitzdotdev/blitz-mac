import Foundation
import Security

private let irisFetchCooldown: TimeInterval = 30

// MARK: - Iris Session (Apple ID cookie-based auth for internal APIs)

extension ASCManager {
    func refreshSubmissionFeedbackIfNeeded() {
        guard let appId = app?.id else { return }
        loadCachedFeedback(appId: appId, versionString: feedbackFocusVersion()?.attributes.versionString)
        loadIrisSession()
        if irisSessionState == .valid {
            Task { await fetchRejectionFeedback() }
        }
    }

    /// Loads cached feedback from disk for the given rejected version. No auth needed.
    func loadCachedFeedback(appId: String, versionString: String? = nil) {
        irisLog("ASCManager.loadCachedFeedback: appId=\(appId) version=\(versionString ?? "all")")
        let projection = IrisArchiveStore.loadProjection(appId: appId)
            ?? IrisFeedbackProjection(appId: appId, cycles: [], lastRebuiltAt: ISO8601DateFormatter().string(from: Date()))
        applyIrisProjection(projection, focusVersionString: versionString)
        rebuildSubmissionHistory(appId: appId)
    }

    func fetchRejectionFeedback(force: Bool = false) async {
        let currentAppId = app?.id ?? "nil"
        irisLog("ASCManager.fetchRejectionFeedback: irisService=\(irisService != nil), appId=\(currentAppId), force=\(force)")
        guard app?.id != nil else {
            irisLog("ASCManager.fetchRejectionFeedback: missing app id, returning")
            return
        }

        guard let appId = app?.id else { return }
        if let existingTask = irisFetchTasksByAppId[appId] {
            irisLog("ASCManager.fetchRejectionFeedback: joining in-flight fetch for appId=\(appId)")
            await existingTask.value
            return
        }

        if !force,
           let lastFetchedAt = irisLastFetchedAtByAppId[appId],
           Date().timeIntervalSince(lastFetchedAt) < irisFetchCooldown {
            irisLog("ASCManager.fetchRejectionFeedback: skipping cooldown for appId=\(appId)")
            return
        }

        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRejectionFeedbackFetch(appId: appId)
        }
        irisFetchTasksByAppId[appId] = task
        await task.value
        irisFetchTasksByAppId[appId] = nil
    }

    private func performRejectionFeedbackFetch(appId: String) async {
        guard let irisService else {
            irisLog("ASCManager.performRejectionFeedbackFetch: missing irisService for appId=\(appId)")
            return
        }

        let focusVersionString = feedbackFocusVersion()?.attributes.versionString

        isLoadingIrisFeedback = true
        irisFeedbackError = nil

        defer {
            irisLastFetchedAtByAppId[appId] = Date()
            isLoadingIrisFeedback = false
            rebuildSubmissionHistory(appId: appId)
            irisLog("ASCManager.fetchRejectionFeedback: done")
        }

        do {
            let threadPages = try await irisService.fetchResolutionCenterThreadPages(appId: appId)
            var threadsById: [String: IrisResolutionCenterThread] = [:]
            for page in threadPages {
                try IrisArchiveStore.recordRawResponse(appId: appId, scopeKey: page.url, data: page.data)
                let pageThreads = (try? JSONDecoder().decode(IrisListResponse<IrisResolutionCenterThread>.self, from: page.data).data) ?? []
                for thread in pageThreads {
                    threadsById[thread.id] = thread
                }
            }
            let threads = threadsById.values.sorted {
                feedbackDate($0.attributes.createdDate) > feedbackDate($1.attributes.createdDate)
            }
            irisLog("ASCManager.fetchRejectionFeedback: got \(threads.count) threads")
            resolutionCenterThreads = threads

            try await withThrowingTaskGroup(of: [IrisRawPage].self) { group in
                for thread in threads {
                    group.addTask {
                        try await irisService.fetchMessagesAndRejectionsPages(threadId: thread.id)
                    }
                }

                for try await pages in group {
                    for page in pages {
                        try IrisArchiveStore.recordRawResponse(appId: appId, scopeKey: page.url, data: page.data)
                    }
                }
            }

            let projection = try IrisArchiveStore.rebuildProjection(appId: appId)
            applyIrisProjection(projection, focusVersionString: focusVersionString)
        } catch let error as IrisError {
            irisLog("ASCManager.fetchRejectionFeedback: IrisError: \(error)")
            if case .sessionExpired = error {
                irisSessionState = .expired
                irisSession = nil
                self.irisService = nil
            } else {
                irisFeedbackError = error.localizedDescription
            }
        } catch {
            irisLog("ASCManager.fetchRejectionFeedback: error: \(error)")
            irisFeedbackError = error.localizedDescription
        }
    }

    func feedbackCycles(forVersionString versionString: String?) -> [IrisFeedbackCycle] {
        let targetVersion = versionString.map(trimmed)
        guard let targetVersion, !targetVersion.isEmpty else { return irisFeedbackCycles }
        return irisFeedbackCycles.filter { trimmed($0.versionString) == targetVersion }
    }

    func hasIrisFeedback(forVersionString versionString: String?) -> Bool {
        !feedbackCycles(forVersionString: versionString).isEmpty
    }

    func latestFeedbackCycle(forVersionString versionString: String?) -> IrisFeedbackCycle? {
        feedbackCycles(forVersionString: versionString).sorted {
            feedbackDate($0.occurredAt) > feedbackDate($1.occurredAt)
        }.first
    }

    func feedbackDisplayVersion(from versions: [ASCAppStoreVersion]) -> ASCAppStoreVersion? {
        if let rejectedVersion = versions.first(where: {
            isFeedbackRejectedState($0.attributes.appStoreState)
        }) {
            return rejectedVersion
        }
        if let versionString = latestFeedbackCycle(forVersionString: nil)?.versionString {
            return versions.first(where: { $0.attributes.versionString == versionString })
        }
        if let rejectedEvent = submissionHistoryEvents.first(where: { $0.eventType == .rejected }) {
            if let versionId = rejectedEvent.versionId,
               let version = versions.first(where: { $0.id == versionId }) {
                return version
            }
            return versions.first(where: { $0.attributes.versionString == rejectedEvent.versionString })
        }
        return nil
    }

    func loadIrisSession() {
        irisLog("ASCManager.loadIrisSession: starting")
        guard let loaded = IrisSession.load() else {
            irisLog("ASCManager.loadIrisSession: no session file found")
            irisSessionState = .noSession
            irisSession = nil
            irisService = nil
            return
        }
        // No time-based expiry — we trust the session until a 401 proves otherwise
        irisLog("ASCManager.loadIrisSession: loaded session with \(loaded.cookies.count) cookies, capturedAt=\(loaded.capturedAt)")
        do {
            try Self.storeWebSessionToKeychain(loaded)
        } catch {
            irisLog("ASCManager.loadIrisSession: asc-web-session backfill FAILED: \(error)")
        }
        irisSession = loaded
        irisService = IrisService(session: loaded)
        irisSessionState = .valid
        irisLog("ASCManager.loadIrisSession: session valid, irisService created")
    }

    func requestWebAuthForMCP() async -> IrisSession? {
        pendingWebAuthContinuation?.resume(returning: nil)
        irisFeedbackError = nil
        showAppleIDLogin = true
        return await withCheckedContinuation { continuation in
            pendingWebAuthContinuation = continuation
        }
    }

    func cancelPendingWebAuth() {
        showAppleIDLogin = false
        pendingWebAuthContinuation?.resume(returning: nil)
        pendingWebAuthContinuation = nil
    }

    func setIrisSession(_ session: IrisSession) {
        irisLog("ASCManager.setIrisSession: \(session.cookies.count) cookies")
        do {
            try session.save()
            irisLog("ASCManager.setIrisSession: saved to native keychain")
        } catch {
            irisLog("ASCManager.setIrisSession: save FAILED: \(error)")
            irisFeedbackError = "Failed to save session: \(error.localizedDescription)"
            showAppleIDLogin = false
            pendingWebAuthContinuation?.resume(returning: nil)
            pendingWebAuthContinuation = nil
            return
        }

        // Also write the shared web session store (keychain + synced session file).
        // If that write fails during an MCP-triggered login, keep the native session
        // but fail the MCP request instead of reporting a false success.
        do {
            try Self.storeWebSessionToKeychain(session)
        } catch {
            irisLog("ASCManager.setIrisSession: asc-web-session save FAILED: \(error)")
            irisFeedbackError = "Failed to save ASC web session: \(error.localizedDescription)"
            if let continuation = pendingWebAuthContinuation {
                pendingWebAuthContinuation = nil
                continuation.resume(returning: nil)
            }
        }

        irisSession = session
        irisService = IrisService(session: session)
        irisSessionState = .valid
        irisLog("ASCManager.setIrisSession: state set to .valid")
        showAppleIDLogin = false

        // Notify MCP tool if it triggered this login
        if let continuation = pendingWebAuthContinuation {
            pendingWebAuthContinuation = nil
            continuation.resume(returning: session)
        }
    }

    func clearIrisSession() {
        irisLog("ASCManager.clearIrisSession")
        let currentSession = irisSession
        IrisSession.delete()
        Self.deleteWebSessionFromKeychain(email: currentSession?.email)
        irisSession = nil
        irisService = nil
        irisSessionState = .noSession
        resolutionCenterThreads = []
        if let appId = app?.id {
            let projection = IrisArchiveStore.loadProjection(appId: appId)
                ?? IrisFeedbackProjection(appId: appId, cycles: [], lastRebuiltAt: ISO8601DateFormatter().string(from: Date()))
            applyIrisProjection(projection, focusVersionString: feedbackFocusVersion()?.attributes.versionString)
            rebuildSubmissionHistory(appId: appId)
        }
    }

    private func applyIrisProjection(
        _ projection: IrisFeedbackProjection,
        focusVersionString: String?
    ) {
        let sortedCycles = projection.cycles.sorted {
            feedbackDate($0.occurredAt) > feedbackDate($1.occurredAt)
        }
        irisFeedbackCycles = sortedCycles
        // The archive projection is the only source of truth. The thread summaries
        // shown in UI are derived from those cycles so we do not maintain parallel caches.
        resolutionCenterThreads = sortedCycles.compactMap { cycle in
            return IrisResolutionCenterThread(
                id: cycle.id,
                attributes: .init(
                    state: nil,
                    createdDate: cycle.threadCreatedAt ?? cycle.occurredAt,
                    lastMessageResponseDate: cycle.lastMessageAt
                )
            )
        }

        let activeCycle = latestFeedbackCycle(forVersionString: focusVersionString)
            ?? latestFeedbackCycle(forVersionString: nil)

        if activeCycle == nil {
            irisLog("ASCManager.applyIrisProjection: no focused cycle for version \(focusVersionString ?? "all")")
        } else {
            irisLog("ASCManager.applyIrisProjection: loaded \(sortedCycles.count) cycles, active=\(activeCycle?.id ?? "nil")")
        }
    }

    private func feedbackFocusVersion() -> ASCAppStoreVersion? {
        let rejectedVersion = appStoreVersions.first(where: {
            isFeedbackRejectedState($0.attributes.appStoreState)
        })
        let pendingVersion = appStoreVersions.first(where: {
            isFeedbackPendingState($0.attributes.appStoreState)
        })
        return rejectedVersion ?? pendingVersion
    }

    private func isFeedbackRejectedState(_ state: String?) -> Bool {
        let normalized = trimmed(state).uppercased()
        return normalized == "REJECTED" || normalized == "METADATA_REJECTED"
    }

    private func isFeedbackPendingState(_ state: String?) -> Bool {
        let normalized = trimmed(state).uppercased()
        guard !normalized.isEmpty else { return false }
        return normalized != "READY_FOR_SALE"
            && normalized != "REMOVED_FROM_SALE"
            && normalized != "DEVELOPER_REMOVED_FROM_SALE"
    }

    private func feedbackDate(_ iso: String?) -> Date {
        irisArchiveSortDate(iso)
    }
}

struct IrisSession: Codable, Sendable {
    var cookies: [IrisCookie]
    var email: String?
    var capturedAt: Date

    struct IrisCookie: Codable, Sendable {
        let name: String
        let value: String
        let domain: String
        let path: String
    }

    private static let keychainService = "dev.blitz.iris-session"
    private static let keychainAccount = "iris-cookies"

    static func load() -> IrisSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(IrisSession.self, from: data)
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        // Delete any existing item first
        Self.delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "IrisSession", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Failed to save session to Keychain (status: \(status))"])
        }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Iris API Response Models

struct IrisResolutionCenterThread: Decodable, Identifiable {
    let id: String
    let attributes: Attributes

    struct Attributes: Decodable {
        let state: String?
        let createdDate: String?
        let lastMessageResponseDate: String?
    }
}

struct IrisResolutionCenterMessage: Decodable, Identifiable {
    let id: String
    let attributes: Attributes

    struct Attributes: Decodable {
        let messageBody: String?
        let createdDate: String?
    }
}

struct IrisReviewRejection: Decodable, Identifiable {
    let id: String
    let attributes: Attributes

    struct Attributes: Decodable {
        let reasons: [Reason]?
    }

    struct Reason: Decodable {
        let reasonSection: String?
        let reasonDescription: String?
        let reasonCode: String?
    }
}

// MARK: - Iris Feedback Cache

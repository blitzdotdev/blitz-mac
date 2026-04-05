import Foundation

extension MCPExecutor {
    // MARK: - Build Pipeline Tools

    struct UploadedArtifactMetadata {
        let shortVersion: String?
        let buildNumber: String?
        let hasEncryptionDeclaration: Bool
    }

    private struct BuildUploadObservation {
        let upload: ASCBuildUpload?
        let build: ASCBuild?
        let timedOut: Bool
    }

    static func artifactMetadata(fromPlistXML plistXML: String) -> UploadedArtifactMetadata? {
        guard let data = plistXML.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }

        func cleanedString(_ value: Any?) -> String? {
            guard let value = value as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return UploadedArtifactMetadata(
            shortVersion: cleanedString(plist["CFBundleShortVersionString"]),
            buildNumber: cleanedString(plist["CFBundleVersion"]),
            hasEncryptionDeclaration: plist.keys.contains("ITSAppUsesNonExemptEncryption")
        )
    }

    static func buildUploadProcessingHint(codes: [String]) -> String? {
        let normalized = Set(codes.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })

        let appIconCodes: Set<String> = ["90022", "90023", "90713"]
        if !normalized.isDisjoint(with: appIconCodes) {
            return "Likely cause: the app icon payload is missing or invalid. Verify AppIcon.appiconset includes a valid 1024x1024 App Store icon plus the required platform icon sizes, then rebuild."
        }

        return nil
    }

    private static func ascPlatformString(for platform: ProjectPlatform) -> String {
        platform == .macOS ? "MAC_OS" : "IOS"
    }

    private static func parseASCDate(_ value: String?) -> Date? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: trimmed) {
            return parsed
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }

    private static func buildUploadAssociationDate(_ upload: ASCBuildUpload) -> Date? {
        parseASCDate(upload.attributes.createdDate) ?? parseASCDate(upload.attributes.uploadedDate)
    }

    private static func buildUploadStateEntries(
        _ details: [ASCBuildUpload.Attributes.AssetState.StateDetail]?
    ) -> [[String: Any]] {
        (details ?? []).map { detail in
            var entry: [String: Any] = [:]
            if let code = detail.code, !code.isEmpty {
                entry["code"] = code
            }
            if let message = detail.message, !message.isEmpty {
                entry["message"] = message
            }
            return entry
        }.filter { !$0.isEmpty }
    }

    private static func buildUploadStatusMessage(upload: ASCBuildUpload?, build: ASCBuild?) -> String {
        if let build {
            let buildState = build.attributes.processingState ?? "UNKNOWN"
            return "Build \(build.attributes.version) is \(buildState) on App Store Connect."
        }

        if let upload {
            let uploadState = upload.attributes.state?.state ?? "UNKNOWN"
            return "Upload \(upload.id) is \(uploadState) on App Store Connect."
        }

        return "Upload committed, but the App Store Connect upload record is not visible yet."
    }

    private static func isTerminalBuildState(_ state: String?) -> Bool {
        guard let state else {
            return false
        }
        let normalized = state.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else {
            return false
        }
        return ["VALID", "INVALID", "FAILED"].contains(normalized)
    }

    private func findRecentBuildUpload(
        service: AppStoreConnectService,
        appId: String,
        metadata: UploadedArtifactMetadata,
        platform: ProjectPlatform,
        uploadStartedAt: Date,
        uploadCompletedAt: Date
    ) async throws -> ASCBuildUpload? {
        guard let shortVersion = metadata.shortVersion,
              let buildNumber = metadata.buildNumber else {
            return nil
        }

        let uploads = try await service.fetchBuildUploads(
            appId: appId,
            shortVersion: shortVersion,
            buildNumber: buildNumber,
            platform: Self.ascPlatformString(for: platform),
            limit: 50
        )

        let lowerBound = uploadStartedAt.addingTimeInterval(-5)
        let upperBound = uploadCompletedAt.addingTimeInterval(60)
        for upload in uploads {
            guard let associationAt = Self.buildUploadAssociationDate(upload) else { continue }
            guard associationAt >= lowerBound, associationAt <= upperBound else { continue }
            return upload
        }

        return nil
    }

    private func observeBuildUpload(
        service: AppStoreConnectService,
        appId: String,
        preferredUploadId: String?,
        metadata: UploadedArtifactMetadata?,
        platform: ProjectPlatform,
        uploadStartedAt: Date,
        uploadCompletedAt: Date,
        waitBudget: TimeInterval,
        pollInterval: TimeInterval = 3,
        onProgress: @escaping @Sendable (String) -> Void
    ) async -> BuildUploadObservation {
        let deadline = Date().addingTimeInterval(max(0, waitBudget))
        var resolvedUploadId = preferredUploadId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedUploadId?.isEmpty == true {
            resolvedUploadId = nil
        }
        var lastUpload: ASCBuildUpload?
        var lastBuild: ASCBuild?
        var lastProgressMessage: String?
        var waited = false

        while true {
            do {
                if resolvedUploadId == nil,
                   let metadata,
                   let matchedUpload = try await findRecentBuildUpload(
                       service: service,
                       appId: appId,
                       metadata: metadata,
                       platform: platform,
                       uploadStartedAt: uploadStartedAt,
                       uploadCompletedAt: uploadCompletedAt
                   ) {
                    resolvedUploadId = matchedUpload.id
                    lastUpload = matchedUpload
                }

                if let resolvedUploadId {
                    let upload = try await service.fetchBuildUpload(id: resolvedUploadId)
                    lastUpload = upload
                    if let buildId = upload.buildId, !buildId.isEmpty {
                        lastBuild = try? await service.fetchBuild(id: buildId)
                    }

                    let progressMessage = Self.buildUploadStatusMessage(upload: upload, build: lastBuild)
                    if progressMessage != lastProgressMessage {
                        onProgress(progressMessage)
                        lastProgressMessage = progressMessage
                    }

                    if upload.attributes.state?.state?.uppercased() == "FAILED"
                        || Self.isTerminalBuildState(lastBuild?.attributes.processingState) {
                        return BuildUploadObservation(upload: lastUpload, build: lastBuild, timedOut: false)
                    }
                }
            } catch {
                // Best-effort status observation only; the upload itself already succeeded.
            }

            if Date() >= deadline {
                break
            }

            waited = true
            try? await Task.sleep(for: .seconds(pollInterval))
        }

        return BuildUploadObservation(upload: lastUpload, build: lastBuild, timedOut: waited)
    }

    func executeSetupSigning(_ args: [String: Any]) async throws -> [String: Any] {
        let (optCtx, err) = await requireBuildContext()
        guard let ctx = optCtx else { return err! }
        let project = ctx.project
        let bundleId = ctx.bundleId
        let service = ctx.service
        let teamId = args["teamId"] as? String ?? (ctx.teamId.isEmpty ? nil : ctx.teamId)

        await MainActor.run {
            appState.ascManager.buildPipelinePhase = .signingSetup
            appState.ascManager.buildPipelineMessage = "Setting up signing…"
        }

        let pipeline = BuildPipelineService()
        let appStateRef = appState
        do {
            let projectPlatform = await MainActor.run { project.platform }
            let result = try await withThrowingTimeout(seconds: 300) {
                try await pipeline.setupSigning(
                    projectPath: project.path,
                    bundleId: bundleId,
                    teamId: teamId,
                    ascService: service,
                    platform: projectPlatform,
                    onProgress: { msg in
                        Task { @MainActor in
                            appStateRef.ascManager.buildPipelineMessage = msg
                        }
                    }
                )
            }

            if !result.teamId.isEmpty {
                await MainActor.run {
                    let storage = ProjectStorage()
                    guard var metadata = storage.readMetadata(projectId: project.id) else { return }
                    metadata.teamId = result.teamId
                    try? storage.writeMetadata(projectId: project.id, metadata: metadata)
                }
            }

            await MainActor.run {
                appState.ascManager.buildPipelinePhase = .idle
                appState.ascManager.buildPipelineMessage = ""
            }

            var resultDict: [String: Any] = [
                "success": true,
                "bundleIdResourceId": result.bundleIdResourceId,
                "certificateId": result.certificateId,
                "profileUUID": result.profileUUID,
                "teamId": result.teamId,
                "log": result.log
            ]
            if let installerCertId = result.installerCertificateId {
                resultDict["installerCertificateId"] = installerCertId
            }
            return mcpJSON(resultDict)
        } catch {
            await MainActor.run {
                appState.ascManager.buildPipelinePhase = .idle
                appState.ascManager.buildPipelineMessage = ""
            }
            return mcpText("Error in signing setup: \(error.localizedDescription)")
        }
    }

    func executeBuildIPA(_ args: [String: Any]) async throws -> [String: Any] {
        let (optCtx, err) = await requireBuildContext(needsTeamId: true)
        guard let ctx = optCtx else { return err! }
        let project = ctx.project
        let bundleId = ctx.bundleId
        let teamId = ctx.teamId

        let scheme = args["scheme"] as? String
        let configuration = args["configuration"] as? String

        await MainActor.run {
            appState.ascManager.buildPipelinePhase = .archiving
            appState.ascManager.buildPipelineMessage = "Starting build…"
        }

        let pipeline = BuildPipelineService()
        let appStateRef = appState
        do {
            let buildPlatform = await MainActor.run { project.platform }
            let result = try await pipeline.buildIPA(
                projectPath: project.path,
                bundleId: bundleId,
                teamId: teamId,
                scheme: scheme,
                configuration: configuration,
                platform: buildPlatform,
                onProgress: { msg in
                    Task { @MainActor in
                        if msg.contains("ARCHIVE SUCCEEDED") || msg.contains("-exportArchive") {
                            appStateRef.ascManager.buildPipelinePhase = .exporting
                        }
                        appStateRef.ascManager.buildPipelineMessage = String(msg.prefix(120))
                    }
                }
            )

            await MainActor.run {
                appState.ascManager.buildPipelinePhase = .idle
                appState.ascManager.buildPipelineMessage = ""
            }

            return mcpJSON([
                "success": true,
                "ipaPath": result.ipaPath,
                "archivePath": result.archivePath,
                "log": result.log
            ])
        } catch {
            await MainActor.run {
                appState.ascManager.buildPipelinePhase = .idle
                appState.ascManager.buildPipelineMessage = ""
            }
            return mcpText("Error building IPA: \(error.localizedDescription)")
        }
    }

    func executeUploadToTestFlight(_ args: [String: Any]) async throws -> [String: Any] {
        guard let credentials = await MainActor.run(body: { appState.ascManager.credentials }) else {
            return mcpText("Error: ASC credentials not configured.")
        }
        guard await MainActor.run(body: { appState.activeProject }) != nil else {
            return mcpText("Error: no active project.")
        }
        let commandStartedAt = Date()

        let ipaPath: String
        if let path = args["ipaPath"] as? String {
            ipaPath = (path as NSString).expandingTildeInPath
        } else {
            let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            let tmpContents = try FileManager.default.contentsOfDirectory(
                at: tmpURL,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )
            let exportDirs = tmpContents.filter { $0.lastPathComponent.hasPrefix("BlitzExport-") }
                .sorted { a, b in
                    let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                        ?? .distantPast
                    let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                        ?? .distantPast
                    return aDate > bDate
                }

            let searchExts: Set<String> = ["ipa", "pkg"]
            var foundArtifact: String?
            for dir in exportDirs {
                let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                if let match = files.first(where: { searchExts.contains($0.pathExtension) }) {
                    foundArtifact = match.path
                    break
                }
            }
            guard let found = foundArtifact else {
                return mcpText("Error: no IPA/PKG path provided and no recent build found. Run app_store_build first.")
            }
            ipaPath = found
        }

        guard FileManager.default.fileExists(atPath: ipaPath) else {
            return mcpText("Error: IPA not found at \(ipaPath)")
        }

        let skipPolling = args["skipPolling"] as? Bool ?? false
        let appId = await MainActor.run { appState.ascManager.app?.id }
        let service = await MainActor.run { appState.ascManager.service }
        var artifactMetadata: UploadedArtifactMetadata?

        let isIPA = ipaPath.hasSuffix(".ipa")
        var existingBuildNumbers: Set<String> = []
        do {
            guard isIPA else { throw NSError(domain: "skip", code: 0) }
            let plistXML = try await ProcessRunner.run(
                "/bin/bash",
                arguments: ["-c", "unzip -p '\(ipaPath)' 'Payload/*.app/Info.plist' | plutil -convert xml1 -o - -"]
            )
            artifactMetadata = Self.artifactMetadata(fromPlistXML: plistXML)

            if artifactMetadata?.hasEncryptionDeclaration != true {
                return mcpText(
                    "Error: ITSAppUsesNonExemptEncryption is not set in the IPA's Info.plist. "
                        + "Without this key, App Store Connect will require manual encryption compliance confirmation in the web UI after every upload. "
                        + "Fix: add INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO to your Xcode build settings (both Debug and Release), then rebuild. "
                        + "Or add <key>ITSAppUsesNonExemptEncryption</key><false/> directly to Info.plist."
                )
            }

            if let buildNumber = artifactMetadata?.buildNumber, let appId, let service {
                let builds = try await service.fetchBuilds(appId: appId)
                existingBuildNumbers = Set(builds.map(\.attributes.version))
                if existingBuildNumbers.contains(buildNumber) {
                    let maxVersion = existingBuildNumbers.compactMap { Int($0) }.max() ?? 0
                    return mcpText(
                        "Error: build version \(buildNumber) already exists in App Store Connect. "
                            + "Existing build versions: \(existingBuildNumbers.sorted().joined(separator: ", ")). "
                            + "The next valid build version is \(maxVersion + 1). "
                            + "Update CFBundleVersion in Info.plist (or CURRENT_PROJECT_VERSION in the Xcode build settings) and rebuild."
                    )
                }
            }
        } catch {
            // Non-fatal — proceed with upload and let altool catch any issues.
        }

        if existingBuildNumbers.isEmpty, let appId, let service {
            existingBuildNumbers = Set((try? await service.fetchBuilds(appId: appId))?.map(\.attributes.version) ?? [])
        }

        await MainActor.run {
            appState.ascManager.buildPipelinePhase = .uploading
            appState.ascManager.buildPipelineMessage = "Uploading IPA…"
        }

        let pipeline = BuildPipelineService()
        let appStateRef = appState
        do {
            let uploadPlatform = await MainActor.run { appState.activeProject?.platform ?? .iOS }
            let uploadStartedAt = Date()
            let result = try await pipeline.uploadToTestFlight(
                ipaPath: ipaPath,
                keyId: credentials.keyId,
                issuerId: credentials.issuerId,
                privateKeyPEM: credentials.privateKey,
                appId: appId,
                ascService: service,
                skipPolling: skipPolling,
                platform: uploadPlatform,
                onProgress: { msg in
                    Task { @MainActor in
                        appStateRef.ascManager.buildPipelineMessage = String(msg.prefix(120))
                    }
                }
            )
            let uploadCompletedAt = Date()

            var allLog = result.log
            var observedUpload: ASCBuildUpload?
            var observedBuild: ASCBuild?

            func autoAttachBuildIfPossible(_ build: ASCBuild) async {
                guard let service else { return }

                allLog.append("Build processing complete!")
                try? await service.patchBuildEncryption(
                    buildId: build.id,
                    usesNonExemptEncryption: false
                )

                let versionId = await MainActor.run(body: { () -> String? in
                    let asc = appStateRef.ascManager
                    if let selectedVersion = asc.selectedVersion,
                       ASCReleaseStatus.isEditable(selectedVersion.attributes.appStoreState) {
                        return selectedVersion.id
                    }
                    return asc.editableVersion?.id
                })
                guard let versionId else { return }

                do {
                    try await service.attachBuild(versionId: versionId, buildId: build.id)
                    allLog.append("Build \(build.attributes.version) attached to app store version.")
                    await ASCUpdateLogger.shared.event("build_pipeline_auto_attach_succeeded", metadata: [
                        "buildId": build.id,
                        "buildVersion": build.attributes.version,
                        "versionId": versionId,
                    ])
                    await MainActor.run {
                        if appStateRef.ascManager.selectedVersion?.id == versionId {
                            appStateRef.ascManager.selectedVersionBuild = build
                        }
                    }
                } catch {
                    allLog.append("Warning: could not auto-attach build - \(error.localizedDescription)")
                    await ASCUpdateLogger.shared.event("build_pipeline_auto_attach_failed", metadata: [
                        "buildId": build.id,
                        "error": error.localizedDescription,
                        "versionId": versionId,
                    ])
                }
            }

            if let appId, let service {
                let maxObservationBudget: TimeInterval = skipPolling ? 6 : 25
                let remainingBudget = max(0, 95 - Date().timeIntervalSince(commandStartedAt))
                let observation = await observeBuildUpload(
                    service: service,
                    appId: appId,
                    preferredUploadId: result.uploadId,
                    metadata: artifactMetadata,
                    platform: uploadPlatform,
                    uploadStartedAt: uploadStartedAt,
                    uploadCompletedAt: uploadCompletedAt,
                    waitBudget: min(maxObservationBudget, remainingBudget),
                    onProgress: { msg in
                        Task { @MainActor in
                            appStateRef.ascManager.buildPipelinePhase = .processing
                            appStateRef.ascManager.buildPipelineMessage = String(msg.prefix(120))
                        }
                    }
                )

                observedUpload = observation.upload
                observedBuild = observation.build
                if observation.timedOut {
                    allLog.append("Stopped waiting before the tool timeout; returning the latest upload/build state instead.")
                }
                if let observedUpload {
                    allLog.append("Observed ASC upload \(observedUpload.id) state: \(observedUpload.attributes.state?.state ?? "UNKNOWN")")
                }
                if let observedBuild {
                    allLog.append("Observed ASC build \(observedBuild.attributes.version) state: \(observedBuild.attributes.processingState ?? "UNKNOWN")")
                } else if let buildNumber = artifactMetadata?.buildNumber,
                          let builds = try? await service.fetchBuilds(appId: appId),
                          let build = builds.first(where: {
                              $0.attributes.version == buildNumber && !existingBuildNumbers.contains($0.attributes.version)
                          }) {
                    observedBuild = build
                    allLog.append("Observed ASC build \(build.attributes.version) state: \(build.attributes.processingState ?? "UNKNOWN")")
                }
            }

            let uploadState = observedUpload?.attributes.state?.state
                ?? (result.uploadCommitted ? "UPLOAD_COMMITTED" : "UNKNOWN")
            let buildState = observedBuild?.attributes.processingState ?? result.processingState ?? "UNKNOWN"
            let buildNumber = observedBuild?.attributes.version ?? artifactMetadata?.buildNumber ?? result.buildVersion
            let uploadErrorCodes = (observedUpload?.attributes.state?.errors ?? []).compactMap(\.code)
            let diagnosticHint = Self.buildUploadProcessingHint(codes: uploadErrorCodes)
            let uploadFailed = uploadState.uppercased() == "FAILED"
            let buildFailed = ["INVALID", "FAILED"].contains(buildState.uppercased())
            let buildValidated = buildState.uppercased() == "VALID"

            if let diagnosticHint {
                allLog.append(diagnosticHint)
            }
            if uploadFailed {
                allLog.append("App Store Connect rejected the upload during ingest.")
            } else if buildFailed {
                allLog.append("Build processing failed on App Store Connect.")
            } else if buildValidated, let observedBuild {
                await autoAttachBuildIfPossible(observedBuild)
            }

            await MainActor.run {
                appState.ascManager.buildPipelinePhase = .idle
                appState.ascManager.buildPipelineMessage = ""
            }
            await appState.ascManager.refreshTabData(.builds)

            let followUpRequired = !(uploadFailed || buildFailed || buildValidated)
            var response: [String: Any] = [
                "success": !(uploadFailed || buildFailed),
                "uploadCommitted": result.uploadCommitted,
                "processingState": buildState,
                "uploadState": uploadState,
                "followUpRequired": followUpRequired,
                "message": Self.buildUploadStatusMessage(upload: observedUpload, build: observedBuild),
                "log": allLog
            ]
            if let uploadId = observedUpload?.id ?? result.uploadId {
                response["uploadId"] = uploadId
            }
            if let fileId = result.fileId {
                response["fileId"] = fileId
            }
            if let buildNumber {
                response["buildNumber"] = buildNumber
                response["buildVersion"] = buildNumber
            }
            if let shortVersion = artifactMetadata?.shortVersion {
                response["versionString"] = shortVersion
            }
            if let buildId = observedBuild?.id {
                response["buildId"] = buildId
            }
            let uploadErrors = Self.buildUploadStateEntries(observedUpload?.attributes.state?.errors)
            if !uploadErrors.isEmpty {
                response["uploadErrors"] = uploadErrors
            }
            let uploadWarnings = Self.buildUploadStateEntries(observedUpload?.attributes.state?.warnings)
            if !uploadWarnings.isEmpty {
                response["uploadWarnings"] = uploadWarnings
            }
            if let diagnosticHint {
                response["diagnosticHint"] = diagnosticHint
            }
            return mcpJSON(response)
        } catch {
            await MainActor.run {
                appState.ascManager.buildPipelinePhase = .idle
                appState.ascManager.buildPipelineMessage = ""
            }
            return mcpText("Error uploading to TestFlight: \(error.localizedDescription)")
        }
    }
}

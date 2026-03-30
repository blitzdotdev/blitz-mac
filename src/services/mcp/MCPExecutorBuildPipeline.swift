import Foundation

extension MCPExecutor {
    // MARK: - Build Pipeline Tools

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

        let isIPA = ipaPath.hasSuffix(".ipa")
        var existingVersions: Set<String> = []
        do {
            guard isIPA else { throw NSError(domain: "skip", code: 0) }
            let plistXML = try await ProcessRunner.run(
                "/bin/bash",
                arguments: ["-c", "unzip -p '\(ipaPath)' 'Payload/*.app/Info.plist' | plutil -convert xml1 -o - -"]
            )

            let ipaVersion: String? = {
                guard let range = plistXML.range(of: "<key>CFBundleVersion</key>"),
                      let valueStart = plistXML.range(of: "<string>", range: range.upperBound..<plistXML.endIndex),
                      let valueEnd = plistXML.range(of: "</string>", range: valueStart.upperBound..<plistXML.endIndex) else {
                    return nil
                }
                return String(plistXML[valueStart.upperBound..<valueEnd.lowerBound])
            }()

            let hasEncryptionKey = plistXML.contains("ITSAppUsesNonExemptEncryption")
            if !hasEncryptionKey {
                return mcpText(
                    "Error: ITSAppUsesNonExemptEncryption is not set in the IPA's Info.plist. "
                        + "Without this key, App Store Connect will require manual encryption compliance confirmation in the web UI after every upload. "
                        + "Fix: add INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO to your Xcode build settings (both Debug and Release), then rebuild. "
                        + "Or add <key>ITSAppUsesNonExemptEncryption</key><false/> directly to Info.plist."
                )
            }

            if let ipaVersion, !ipaVersion.isEmpty, let appId, let service {
                let builds = try await service.fetchBuilds(appId: appId)
                existingVersions = Set(builds.map(\.attributes.version))
                if existingVersions.contains(ipaVersion) {
                    let maxVersion = existingVersions.compactMap { Int($0) }.max() ?? 0
                    return mcpText(
                        "Error: build version \(ipaVersion) already exists in App Store Connect. "
                            + "Existing build versions: \(existingVersions.sorted().joined(separator: ", ")). "
                            + "The next valid build version is \(maxVersion + 1). "
                            + "Update CFBundleVersion in Info.plist (or CURRENT_PROJECT_VERSION in the Xcode build settings) and rebuild."
                    )
                }
            }
        } catch {
            // Non-fatal — proceed with upload and let altool catch any issues.
        }

        if existingVersions.isEmpty, let appId, let service {
            existingVersions = Set((try? await service.fetchBuilds(appId: appId))?.map(\.attributes.version) ?? [])
        }

        await MainActor.run {
            appState.ascManager.buildPipelinePhase = .uploading
            appState.ascManager.buildPipelineMessage = "Uploading IPA…"
        }

        let pipeline = BuildPipelineService()
        let appStateRef = appState
        do {
            let uploadPlatform = await MainActor.run { appState.activeProject?.platform ?? .iOS }
            let result = try await pipeline.uploadToTestFlight(
                ipaPath: ipaPath,
                keyId: credentials.keyId,
                issuerId: credentials.issuerId,
                privateKeyPEM: credentials.privateKey,
                appId: appId,
                ascService: service,
                skipPolling: true,
                platform: uploadPlatform,
                onProgress: { msg in
                    Task { @MainActor in
                        appStateRef.ascManager.buildPipelineMessage = String(msg.prefix(120))
                    }
                }
            )

            var allLog = result.log
            var finalState = result.processingState
            var finalVersion = result.buildVersion

            if !skipPolling, let appId, let service {
                await MainActor.run {
                    appStateRef.ascManager.buildPipelinePhase = .processing
                    appStateRef.ascManager.buildPipelineMessage = "Waiting for new build to appear…"
                }

                let pollInterval: TimeInterval = 10
                let maxAttempts = 30

                for attempt in 1...maxAttempts {
                    try? await Task.sleep(for: .seconds(pollInterval))

                    guard let builds = try? await service.fetchBuilds(appId: appId) else { continue }

                    if let newBuild = builds.first(where: { !existingVersions.contains($0.attributes.version) }) {
                        let state = newBuild.attributes.processingState ?? "UNKNOWN"
                        let version = newBuild.attributes.version
                        let msg = "Poll \(attempt): build \(version) — \(state)"
                        allLog.append(msg)
                        await MainActor.run {
                            appStateRef.ascManager.buildPipelineMessage = msg
                            appStateRef.ascManager.builds = builds
                        }

                        finalVersion = version
                        finalState = state

                        if state == "VALID" {
                            allLog.append("Build processing complete!")
                            try? await service.patchBuildEncryption(
                                buildId: newBuild.id,
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
                            if let versionId {
                                do {
                                    try await service.attachBuild(versionId: versionId, buildId: newBuild.id)
                                    allLog.append("Build \(version) attached to app store version.")
                                    await ASCUpdateLogger.shared.event("build_pipeline_auto_attach_succeeded", metadata: [
                                        "buildId": newBuild.id,
                                        "buildVersion": version,
                                        "versionId": versionId,
                                    ])
                                    await MainActor.run {
                                        if appStateRef.ascManager.selectedVersion?.id == versionId {
                                            appStateRef.ascManager.selectedVersionBuild = newBuild
                                        }
                                    }
                                } catch {
                                    allLog.append("Warning: could not auto-attach build - \(error.localizedDescription)")
                                    await ASCUpdateLogger.shared.event("build_pipeline_auto_attach_failed", metadata: [
                                        "buildId": newBuild.id,
                                        "error": error.localizedDescription,
                                        "versionId": versionId,
                                    ])
                                }
                            }
                            break
                        } else if state == "INVALID" {
                            allLog.append("Build processing failed with INVALID state.")
                            break
                        }
                    } else {
                        let msg = "Poll \(attempt): new build not yet visible…"
                        allLog.append(msg)
                        await MainActor.run {
                            appStateRef.ascManager.buildPipelineMessage = msg
                        }
                    }
                }
            }

            await MainActor.run {
                appState.ascManager.buildPipelinePhase = .idle
                appState.ascManager.buildPipelineMessage = ""
            }
            await appState.ascManager.refreshTabData(.builds)

            var response: [String: Any] = [
                "success": true,
                "processingState": finalState ?? "UNKNOWN",
                "log": allLog
            ]
            if let version = finalVersion {
                response["buildVersion"] = version
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

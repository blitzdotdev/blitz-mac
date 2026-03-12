import Foundation

/// Thread-safe collector for the last N stderr lines
private final class StderrCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let maxLines: Int

    init(maxLines: Int = 20) {
        self.maxLines = maxLines
    }

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst() }
        lock.unlock()
    }

    var summary: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

/// Handles iOS code signing setup, archiving/exporting IPAs, and uploading to TestFlight.
/// Each method is idempotent — re-running skips already-completed steps via cached signing state.
actor BuildPipelineService {

    // MARK: - Signing State (persisted for idempotency)

    struct SigningState: Codable {
        var bundleIdResourceId: String?
        var certificateId: String?
        var profileUUID: String?
        var profileName: String?
        var teamId: String?
    }

    private let fm = FileManager.default

    private func signingStateURL(bundleId: String) -> URL {
        return BlitzPaths.signing(bundleId: bundleId).appendingPathComponent("signing-state.json")
    }

    private func loadSigningState(bundleId: String) -> SigningState {
        let url = signingStateURL(bundleId: bundleId)
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SigningState.self, from: data) else {
            return SigningState()
        }
        return state
    }

    private func saveSigningState(_ state: SigningState, bundleId: String) throws {
        let url = signingStateURL(bundleId: bundleId)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Setup Signing

    struct SigningResult {
        let bundleIdResourceId: String
        let certificateId: String
        let profileUUID: String
        let teamId: String
        let log: [String]
    }

    func setupSigning(
        projectPath: String,
        bundleId: String,
        teamId: String?,
        ascService: AppStoreConnectService,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> SigningResult {
        var state = loadSigningState(bundleId: bundleId)
        var log: [String] = []

        func emit(_ msg: String) {
            log.append(msg)
            onProgress(msg)
        }

        // 1. Register bundle ID
        let bundleIdResourceId: String
        if let existing = state.bundleIdResourceId {
            emit("Bundle ID already registered: \(existing)")
            bundleIdResourceId = existing
        } else {
            emit("Checking bundle ID '\(bundleId)'...")
            if let found = try await ascService.fetchBundleId(identifier: bundleId) {
                emit("Bundle ID exists: \(found.id)")
                bundleIdResourceId = found.id
            } else {
                emit("Registering bundle ID...")
                let appName = bundleId.split(separator: ".").last.map(String.init) ?? bundleId
                let created = try await ascService.registerBundleId(identifier: bundleId, name: appName)
                emit("Registered bundle ID: \(created.id)")
                bundleIdResourceId = created.id
            }
            state.bundleIdResourceId = bundleIdResourceId
            try saveSigningState(state, bundleId: bundleId)
        }

        // 2. Distribution certificate
        let certificateId: String
        if let existing = state.certificateId {
            emit("Distribution certificate already configured: \(existing)")
            certificateId = existing
        } else {
            emit("Checking distribution certificates...")
            let certs = try await ascService.fetchDistributionCertificates()
            if let cert = certs.first {
                emit("Using existing certificate: \(cert.attributes.displayName ?? cert.id)")
                certificateId = cert.id
            } else {
                emit("No distribution certificate found. Creating one...")
                let signingDir = BlitzPaths.signing(bundleId: bundleId)
                try fm.createDirectory(at: signingDir, withIntermediateDirectories: true)

                let keyPath = signingDir.appendingPathComponent("dist.key").path
                let csrPath = signingDir.appendingPathComponent("dist.csr").path

                // Generate private key
                try await ProcessRunner.run("openssl", arguments: [
                    "genrsa", "-out", keyPath, "2048"
                ], timeout: 30)
                emit("Generated RSA private key")
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath)

                // Generate CSR
                try await ProcessRunner.run("openssl", arguments: [
                    "req", "-new", "-key", keyPath, "-out", csrPath,
                    "-subj", "/CN=Blitz Distribution/O=Blitz/C=US"
                ], timeout: 30)
                let csrContent = try String(contentsOfFile: csrPath, encoding: .utf8)
                emit("Generated CSR")

                // Create certificate via API
                let cert = try await ascService.createCertificate(csrContent: csrContent)
                emit("Created distribution certificate: \(cert.id)")

                // Decode certificate content and import to keychain
                if let certBase64 = cert.attributes.certificateContent,
                   let certData = Data(base64Encoded: certBase64) {
                    let derPath = signingDir.appendingPathComponent("dist.cer").path
                    try certData.write(to: URL(fileURLWithPath: derPath))

                    // Convert DER to PEM
                    let pemPath = signingDir.appendingPathComponent("dist.pem").path
                    try await ProcessRunner.run("openssl", arguments: [
                        "x509", "-inform", "DER", "-in", derPath, "-out", pemPath
                    ], timeout: 30)

                    // Create p12 for keychain import
                    let p12Path = signingDir.appendingPathComponent("dist.p12").path
                    try await ProcessRunner.run("openssl", arguments: [
                        "pkcs12", "-export", "-legacy",
                        "-inkey", keyPath, "-in", pemPath,
                        "-out", p12Path, "-passout", "pass:"
                    ], timeout: 30)
                    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12Path)

                    // Import to keychain
                    try await ProcessRunner.run("security", arguments: [
                        "import", p12Path, "-k",
                        fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains/login.keychain-db").path,
                        "-P", "", "-T", "/usr/bin/codesign",
                        "-T", "/usr/bin/security"
                    ], timeout: 30)
                    emit("Imported certificate to keychain")
                }

                certificateId = cert.id
            }
            state.certificateId = certificateId
            try saveSigningState(state, bundleId: bundleId)
        }

        // 3. Provisioning profile
        let profileUUID: String
        if let existing = state.profileUUID {
            emit("Provisioning profile already installed: \(existing)")
            profileUUID = existing

            // Recover team ID from installed profile if missing
            if state.teamId == nil && teamId == nil {
                let profilePath = fm.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/MobileDevice/Provisioning Profiles/\(existing).mobileprovision").path
                if let extractedTeamId = Self.extractTeamId(from: profilePath) {
                    state.teamId = extractedTeamId
                    try saveSigningState(state, bundleId: bundleId)
                    emit("Extracted team ID from installed profile: \(extractedTeamId)")
                }
            }
        } else {
            emit("Creating provisioning profile...")
            let profileName = "\(bundleId) App Store"
            let profile = try await ascService.createProfile(
                name: profileName,
                bundleIdResourceId: bundleIdResourceId,
                certificateId: certificateId
            )
            emit("Created profile: \(profile.attributes.name)")

            // Decode and install the profile
            if let profileBase64 = profile.attributes.profileContent,
               let profileData = Data(base64Encoded: profileBase64) {

                // Extract UUID from the profile plist
                let uuid = profile.attributes.uuid ?? UUID().uuidString

                let profilesDir = fm.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/MobileDevice/Provisioning Profiles")
                try fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
                let profilePath = profilesDir.appendingPathComponent("\(uuid).mobileprovision")
                try profileData.write(to: profilePath)
                emit("Installed profile at: \(profilePath.path)")
                profileUUID = uuid

                // Extract TeamIdentifier from the provisioning profile
                if state.teamId == nil && teamId == nil {
                    let extractedTeamId = Self.extractTeamId(from: profilePath.path)
                    if let extractedTeamId {
                        state.teamId = extractedTeamId
                        emit("Extracted team ID from profile: \(extractedTeamId)")
                    }
                }
            } else {
                profileUUID = profile.attributes.uuid ?? profile.id
            }

            state.profileUUID = profileUUID
            state.profileName = profile.attributes.name
            try saveSigningState(state, bundleId: bundleId)
        }

        // 4. Configure Xcode project
        let resolvedTeamId = teamId ?? state.teamId ?? ""
        if !resolvedTeamId.isEmpty {
            emit("Configuring pbxproj with team \(resolvedTeamId)...")
            try await configurePbxproj(
                projectPath: projectPath,
                teamId: resolvedTeamId,
                bundleId: bundleId
            )
            state.teamId = resolvedTeamId
            try saveSigningState(state, bundleId: bundleId)
            emit("Xcode project configured")
        } else {
            emit("Warning: no teamId provided — skipping pbxproj configuration")
        }

        return SigningResult(
            bundleIdResourceId: bundleIdResourceId,
            certificateId: certificateId,
            profileUUID: profileUUID,
            teamId: resolvedTeamId,
            log: log
        )
    }

    /// Extract TeamIdentifier from an installed .mobileprovision file using `security cms`
    private static func extractTeamId(from profilePath: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["cms", "-D", "-i", profilePath]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let plistStr = String(data: data, encoding: .utf8),
              let plistData = plistStr.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let teamIds = plist["TeamIdentifier"] as? [String],
              let teamId = teamIds.first else {
            return nil
        }
        return teamId
    }

    /// Update only PRODUCT_BUNDLE_IDENTIFIER in the project's pbxproj.
    /// Public so it can be called from MCPToolExecutor when the user changes bundle ID.
    func updateBundleIdInPbxproj(projectPath: String, bundleId: String) {
        let projectURL = URL(fileURLWithPath: projectPath)
        var searchDirs = [projectURL]
        for name in ["ios", "macos", "apple"] {
            let sub = projectURL.appendingPathComponent(name)
            if fm.fileExists(atPath: sub.path) { searchDirs.append(sub) }
        }
        for dir in searchDirs {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for entry in entries where entry.pathExtension == "xcodeproj" {
                let pbxprojURL = entry.appendingPathComponent("project.pbxproj")
                guard fm.fileExists(atPath: pbxprojURL.path),
                      var content = try? String(contentsOf: pbxprojURL, encoding: .utf8) else { continue }
                let pattern = try! NSRegularExpression(pattern: "PRODUCT_BUNDLE_IDENTIFIER = [^;]*;")
                let replacement = "PRODUCT_BUNDLE_IDENTIFIER = \(bundleId);"
                let range = NSRange(content.startIndex..., in: content)
                if pattern.firstMatch(in: content, range: range) != nil {
                    content = pattern.stringByReplacingMatches(in: content, range: range, withTemplate: replacement)
                } else {
                    content = content.replacingOccurrences(
                        of: "buildSettings = {",
                        with: "buildSettings = {\n\t\t\t\t\(replacement)"
                    )
                }
                try? content.write(to: pbxprojURL, atomically: true, encoding: .utf8)
            }
        }
    }

    private func configurePbxproj(projectPath: String, teamId: String, bundleId: String) async throws {
        // Find .xcodeproj in root or common subdirectories
        let projectURL = URL(fileURLWithPath: projectPath)
        var searchDirs = [projectURL]
        for name in ["ios", "macos", "apple"] {
            let sub = projectURL.appendingPathComponent(name)
            if fm.fileExists(atPath: sub.path) { searchDirs.append(sub) }
        }
        var xcodeprojURL: URL?
        for dir in searchDirs {
            if let match = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "xcodeproj" }) {
                xcodeprojURL = match
                break
            }
        }
        guard let xcodeprojURL else { return }

        let pbxprojURL = xcodeprojURL.appendingPathComponent("project.pbxproj")
        guard fm.fileExists(atPath: pbxprojURL.path) else { return }

        var content = try String(contentsOf: pbxprojURL, encoding: .utf8)

        // Helper: replace existing build setting or insert after "buildSettings = {"
        func ensureBuildSetting(_ key: String, _ value: String) {
            let pattern = try! NSRegularExpression(pattern: "\(key) = [^;]*;")
            let replacement = "\(key) = \(value);"
            let range = NSRange(content.startIndex..., in: content)
            if pattern.firstMatch(in: content, range: range) != nil {
                content = pattern.stringByReplacingMatches(
                    in: content, range: range, withTemplate: replacement
                )
            } else {
                // Insert after each "buildSettings = {" line
                content = content.replacingOccurrences(
                    of: "buildSettings = {",
                    with: "buildSettings = {\n\t\t\t\t\(replacement)"
                )
            }
        }

        // 1. TargetAttributes: inject DevelopmentTeam + ProvisioningStyle = Automatic
        //    Pattern: 24-hex-char target ID = { ... }; inside TargetAttributes
        let targetAttrPattern = try NSRegularExpression(
            pattern: #"(TargetAttributes\s*=\s*\{[^}]*?[A-F0-9]{24}\s*=\s*\{)"#,
            options: [.dotMatchesLineSeparators]
        )
        let attrRange = NSRange(content.startIndex..., in: content)
        // Check if ProvisioningStyle already exists
        if !content.contains("ProvisioningStyle") {
            let matches = targetAttrPattern.matches(in: content, range: attrRange)
            // Process in reverse to preserve indices
            for match in matches.reversed() {
                if let range = Range(match.range(at: 1), in: content) {
                    let insertion = """
                    \(content[range])
                    \t\t\t\t\tDevelopmentTeam = \(teamId);
                    \t\t\t\t\tProvisioningStyle = Automatic;
                    """
                    content.replaceSubrange(range, with: insertion)
                }
            }
        }

        // 2. Build settings: replace or insert
        ensureBuildSetting("CODE_SIGN_STYLE", "Automatic")
        ensureBuildSetting("DEVELOPMENT_TEAM", teamId)
        ensureBuildSetting("PRODUCT_BUNDLE_IDENTIFIER", bundleId)

        // 3. Replace existing DevelopmentTeam everywhere (catches TargetAttributes too)
        let teamPattern = try NSRegularExpression(pattern: #"DevelopmentTeam = [^;]*;"#)
        content = teamPattern.stringByReplacingMatches(
            in: content, range: NSRange(content.startIndex..., in: content),
            withTemplate: "DevelopmentTeam = \(teamId);"
        )

        try content.write(to: pbxprojURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Build IPA

    struct BuildResult {
        let ipaPath: String
        let archivePath: String
        let log: [String]
    }

    func buildIPA(
        projectPath: String,
        bundleId: String,
        teamId: String,
        scheme: String?,
        configuration: String?,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> BuildResult {
        var log: [String] = []

        func emit(_ msg: String) {
            log.append(msg)
            onProgress(msg)
        }

        let projectURL = URL(fileURLWithPath: projectPath)

        // Search for workspace/project in root and common subdirectories (ios/, macos/, etc.)
        let searchDirs: [URL] = {
            var dirs = [projectURL]
            let subdirNames = ["ios", "macos", "apple"]
            for name in subdirNames {
                let sub = projectURL.appendingPathComponent(name)
                if fm.fileExists(atPath: sub.path) { dirs.append(sub) }
            }
            return dirs
        }()

        func findXcodeFiles(ext: String) -> [URL] {
            for dir in searchDirs {
                let matches = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                    .filter { $0.pathExtension == ext } ?? []
                if !matches.isEmpty { return matches }
            }
            return []
        }

        var workspaces = findXcodeFiles(ext: "xcworkspace")
        let xcodeprojs = findXcodeFiles(ext: "xcodeproj")

        // Determine the directory containing the Xcode project (for pod install / build cwd)
        let xcodeDir: String = workspaces.first?.deletingLastPathComponent().path
            ?? xcodeprojs.first?.deletingLastPathComponent().path
            ?? projectPath

        // Run pod install if Podfile exists but no workspace
        let podfilePath = URL(fileURLWithPath: xcodeDir).appendingPathComponent("Podfile").path
        if workspaces.isEmpty && fm.fileExists(atPath: podfilePath) {
            emit("Running pod install...")
            try await ProcessRunner.run("pod", arguments: ["install"],
                                       currentDirectory: xcodeDir, timeout: 300)
            emit("pod install complete")
            // Re-check workspaces after pod install
            workspaces = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: xcodeDir), includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "xcworkspace" } ?? []
        }

        let useWorkspace = !workspaces.isEmpty
        let buildTarget = useWorkspace
            ? workspaces[0].path
            : (xcodeprojs.first?.path ?? "")

        guard !buildTarget.isEmpty else {
            throw ProcessRunner.ProcessError(
                command: "xcodebuild",
                exitCode: -1,
                stderr: "No .xcworkspace or .xcodeproj found in \(projectPath) or its ios/ subdirectory"
            )
        }

        emit("Found Xcode project: \(buildTarget)")

        // Resolve scheme
        let resolvedScheme: String
        if let scheme {
            resolvedScheme = scheme
        } else {
            // Try to detect scheme from xcodebuild -list
            let listOutput = try await ProcessRunner.run("xcodebuild", arguments: [
                "-list",
                useWorkspace ? "-workspace" : "-project",
                buildTarget
            ], currentDirectory: xcodeDir, timeout: 30)
            // Parse first scheme from output
            let lines = listOutput.components(separatedBy: "\n")
            var inSchemes = false
            var detectedScheme: String?
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "Schemes:" {
                    inSchemes = true
                    continue
                }
                if inSchemes && !trimmed.isEmpty {
                    detectedScheme = trimmed
                    break
                }
            }
            resolvedScheme = detectedScheme ?? URL(fileURLWithPath: buildTarget).deletingPathExtension().lastPathComponent
        }
        let config = configuration ?? "Release"

        emit("Building scheme '\(resolvedScheme)' (\(config))...")

        // Archive
        let archivePath = NSTemporaryDirectory() + "BlitzArchive-\(Int(Date().timeIntervalSince1970)).xcarchive"
        let archiveArgs = [
            useWorkspace ? "-workspace" : "-project",
            buildTarget,
            "-scheme", resolvedScheme,
            "-configuration", config,
            "-destination", "generic/platform=iOS",
            "-archivePath", archivePath,
            "-allowProvisioningUpdates",
            "archive",
            "CODE_SIGN_STYLE=Automatic",
            "DEVELOPMENT_TEAM=\(teamId)",
            "PRODUCT_BUNDLE_IDENTIFIER=\(bundleId)"
        ]

        let archiveStderr = StderrCollector()
        let managed = ProcessRunner.stream(
            "xcodebuild",
            arguments: archiveArgs,
            currentDirectory: xcodeDir,
            onStdout: { line in onProgress(line) },
            onStderr: { line in
                onProgress(line)
                archiveStderr.append(line)
            }
        )

        if let launchErr = managed.launchError {
            throw ProcessRunner.ProcessError(
                command: "xcodebuild archive",
                exitCode: -1,
                stderr: "Failed to launch xcodebuild: \(launchErr.localizedDescription)"
            )
        }

        await managed.waitUntilExit()

        guard managed.process.terminationStatus == 0 else {
            let stderrSummary = archiveStderr.summary
            throw ProcessRunner.ProcessError(
                command: "xcodebuild archive",
                exitCode: managed.process.terminationStatus,
                stderr: stderrSummary.isEmpty ? "Archive failed with exit code \(managed.process.terminationStatus)" : stderrSummary
            )
        }
        emit("Archive succeeded: \(archivePath)")

        // Generate ExportOptions.plist
        let exportOptionsPath = NSTemporaryDirectory() + "ExportOptions-\(Int(Date().timeIntervalSince1970)).plist"
        let exportOptions: [String: Any] = [
            "method": "app-store-connect",
            "teamID": teamId,
            "signingStyle": "automatic",
            "uploadBitcode": false,
            "uploadSymbols": true
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: exportOptions,
            format: .xml,
            options: 0
        )
        try plistData.write(to: URL(fileURLWithPath: exportOptionsPath))
        emit("Generated ExportOptions.plist")

        // Export IPA
        let exportPath = NSTemporaryDirectory() + "BlitzExport-\(Int(Date().timeIntervalSince1970))"
        let exportStderr = StderrCollector()
        let exportManaged = ProcessRunner.stream(
            "xcodebuild",
            arguments: [
                "-exportArchive",
                "-archivePath", archivePath,
                "-exportPath", exportPath,
                "-exportOptionsPlist", exportOptionsPath,
                "-allowProvisioningUpdates"
            ],
            currentDirectory: xcodeDir,
            onStdout: { line in onProgress(line) },
            onStderr: { line in
                onProgress(line)
                exportStderr.append(line)
            }
        )

        if let launchErr = exportManaged.launchError {
            throw ProcessRunner.ProcessError(
                command: "xcodebuild -exportArchive",
                exitCode: -1,
                stderr: "Failed to launch xcodebuild: \(launchErr.localizedDescription)"
            )
        }

        await exportManaged.waitUntilExit()

        guard exportManaged.process.terminationStatus == 0 else {
            var stderrSummary = exportStderr.summary

            // Extract real error from IDEDistribution log if available
            // xcodebuild prints "Created bundle at path <log_path>" on export failure
            if let logPathRange = stderrSummary.range(of: "Created bundle at path \""),
               let endQuote = stderrSummary[logPathRange.upperBound...].firstIndex(of: "\"") {
                let logDir = String(stderrSummary[logPathRange.upperBound..<endQuote])
                let errorLogPath = logDir + "/IDEDistribution.standard-log.txt"
                if let logContent = try? String(contentsOfFile: errorLogPath, encoding: .utf8) {
                    // Extract error lines from the log
                    let errorLines = logContent.components(separatedBy: "\n")
                        .filter { $0.contains("error:") || $0.contains("Error Domain") || $0.contains("No profiles") || $0.contains("doesn't match") || $0.contains("provisioning") }
                    if !errorLines.isEmpty {
                        stderrSummary += "\n\n--- Distribution Log Errors ---\n" + errorLines.joined(separator: "\n")
                    }
                }
            }

            throw ProcessRunner.ProcessError(
                command: "xcodebuild -exportArchive",
                exitCode: exportManaged.process.terminationStatus,
                stderr: stderrSummary.isEmpty ? "Export failed with exit code \(exportManaged.process.terminationStatus)" : stderrSummary
            )
        }

        // Find the IPA
        let exportedFiles = try fm.contentsOfDirectory(at: URL(fileURLWithPath: exportPath),
                                                        includingPropertiesForKeys: nil)
        guard let ipaURL = exportedFiles.first(where: { $0.pathExtension == "ipa" }) else {
            throw ProcessRunner.ProcessError(
                command: "xcodebuild -exportArchive",
                exitCode: -1,
                stderr: "No IPA found in export directory: \(exportPath)"
            )
        }

        emit("IPA exported: \(ipaURL.path)")

        return BuildResult(
            ipaPath: ipaURL.path,
            archivePath: archivePath,
            log: log
        )
    }

    // MARK: - Upload to TestFlight

    struct UploadResult {
        let buildVersion: String?
        let processingState: String?
        let log: [String]
    }

    func uploadToTestFlight(
        ipaPath: String,
        keyId: String,
        issuerId: String,
        privateKeyPEM: String,
        appId: String?,
        ascService: AppStoreConnectService?,
        skipPolling: Bool,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> UploadResult {
        var log: [String] = []

        func emit(_ msg: String) {
            log.append(msg)
            onProgress(msg)
        }

        // Place .p8 key for altool/notarytool
        let keyDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".appstoreconnect/private_keys")
        try fm.createDirectory(at: keyDir, withIntermediateDirectories: true)
        let keyPath = keyDir.appendingPathComponent("AuthKey_\(keyId).p8")
        try privateKeyPEM.write(to: keyPath, atomically: true, encoding: .utf8)
        emit("API key placed at \(keyPath.path)")

        // Upload using xcrun altool
        emit("Uploading IPA to App Store Connect...")
        let uploadStderr = StderrCollector()
        let uploadManaged = ProcessRunner.stream(
            "xcrun",
            arguments: [
                "altool", "--upload-app",
                "-f", ipaPath,
                "-t", "ios",
                "--apiKey", keyId,
                "--apiIssuer", issuerId
            ],
            onStdout: { line in onProgress(line) },
            onStderr: { line in
                onProgress(line)
                uploadStderr.append(line)
            }
        )

        if let launchErr = uploadManaged.launchError {
            throw ProcessRunner.ProcessError(
                command: "xcrun altool --upload-app",
                exitCode: -1,
                stderr: "Failed to launch xcrun: \(launchErr.localizedDescription)"
            )
        }

        await uploadManaged.waitUntilExit()

        guard uploadManaged.process.terminationStatus == 0 else {
            let stderrSummary = uploadStderr.summary
            throw ProcessRunner.ProcessError(
                command: "xcrun altool --upload-app",
                exitCode: uploadManaged.process.terminationStatus,
                stderr: stderrSummary.isEmpty ? "Upload failed with exit code \(uploadManaged.process.terminationStatus)" : stderrSummary
            )
        }
        emit("Upload complete. Build is processing on App Store Connect.")

        // Poll for build processing
        if !skipPolling, let appId, let ascService {
            emit("Polling for build processing status...")
            let pollInterval: TimeInterval = 30
            let maxAttempts = 60 // 30 minutes
            for attempt in 1...maxAttempts {
                try await Task.sleep(for: .seconds(pollInterval))
                if let build = try await ascService.fetchLatestBuild(appId: appId) {
                    let state = build.attributes.processingState ?? "UNKNOWN"
                    emit("Poll \(attempt): build \(build.attributes.version) — \(state)")
                    if state == "VALID" {
                        emit("Build processing complete!")
                        return UploadResult(
                            buildVersion: build.attributes.version,
                            processingState: state,
                            log: log
                        )
                    } else if state == "INVALID" {
                        emit("Build processing failed with INVALID state")
                        return UploadResult(
                            buildVersion: build.attributes.version,
                            processingState: state,
                            log: log
                        )
                    }
                }
            }
            emit("Polling timed out after 30 minutes")
        }

        return UploadResult(
            buildVersion: nil,
            processingState: skipPolling ? "SKIPPED_POLLING" : "TIMEOUT",
            log: log
        )
    }
}

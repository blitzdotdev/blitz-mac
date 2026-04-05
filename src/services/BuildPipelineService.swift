import Foundation

/// Thread-safe collector that keeps enough process output to surface the
/// meaningful failure context instead of only the last stderr lines.
final class ProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let maxStoredLines: Int
    private let maxSummaryLines: Int

    init(maxStoredLines: Int = 400, maxSummaryLines: Int = 60) {
        self.maxStoredLines = maxStoredLines
        self.maxSummaryLines = maxSummaryLines
    }

    func appendStdout(_ chunk: String) {
        append(chunk)
    }

    func appendStderr(_ chunk: String) {
        append(chunk)
    }

    private func append(_ chunk: String) {
        let normalized = chunk.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let splitLines = normalized.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !splitLines.isEmpty else { return }

        lock.lock()
        lines.append(contentsOf: splitLines)
        if lines.count > maxStoredLines {
            lines.removeFirst(lines.count - maxStoredLines)
        }
        lock.unlock()
    }

    var combinedText: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    var summary: String {
        lock.lock()
        let snapshot = lines
        lock.unlock()

        guard !snapshot.isEmpty else { return "" }

        let interestingIndexes = snapshot.indices.filter { Self.isInteresting(snapshot[$0]) }
        if interestingIndexes.isEmpty {
            return Array(snapshot.suffix(maxSummaryLines)).joined(separator: "\n")
        }

        var selectedIndexes: [Int] = []
        for index in interestingIndexes {
            let start = max(snapshot.startIndex, index - 2)
            let end = min(snapshot.index(before: snapshot.endIndex), index + 2)
            selectedIndexes.append(contentsOf: start...end)
        }
        selectedIndexes.append(contentsOf: snapshot.indices.suffix(8))

        var seen: Set<Int> = []
        let filtered = selectedIndexes
            .filter { seen.insert($0).inserted }
            .sorted()
            .suffix(maxSummaryLines)

        return filtered.map { snapshot[$0] }.joined(separator: "\n")
    }

    private static func isInteresting(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        return lowercased.contains("error:")
            || lowercased.contains("compileassetcatalogvariant")
            || lowercased.contains("asset catalog")
            || lowercased.contains("appicon")
            || lowercased.contains(".appiconset")
            || lowercased.contains("icon set")
            || lowercased.contains("app store icon")
            || lowercased.contains("actool")
            || lowercased.contains("invalid image")
            || lowercased.contains("missing required icon")
    }

    var lastLogBundlePath: String? {
        let text = combinedText
        guard let range = text.range(of: "Created bundle at path \""),
              let endQuote = text[range.upperBound...].firstIndex(of: "\"") else {
            return nil
        }
        return String(text[range.upperBound..<endQuote])
    }

    var allLines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

/// Handles iOS code signing setup, archiving/exporting IPAs, and uploading to TestFlight.
/// Each method is idempotent — re-running skips already-completed steps via cached signing state.
actor BuildPipelineService {
    private static let helperUploadVerifyTimeout = "15s"

    // MARK: - Signing State (persisted for idempotency)

    struct SigningState: Codable {
        var bundleIdResourceId: String?
        var certificateId: String?
        var installerCertificateId: String?
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
        let installerCertificateId: String?
        let profileUUID: String
        let teamId: String
        let log: [String]
    }

    func setupSigning(
        projectPath: String,
        bundleId: String,
        teamId: String?,
        ascService: AppStoreConnectService,
        platform: ProjectPlatform = .iOS,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> SigningResult {
        var state = loadSigningState(bundleId: bundleId)
        var log: [String] = []

        let isMacOS = platform == .macOS
        let certType = isMacOS ? "MAC_APP_DISTRIBUTION" : "DISTRIBUTION"
        let bundleIdPlatform = isMacOS ? "MAC_OS" : "IOS"
        let profileType = isMacOS ? "MAC_APP_STORE" : "IOS_APP_STORE"

        func emit(_ msg: String) {
            log.append(msg)
            onProgress(msg)
        }

        if isMacOS {
            emit("Setting up macOS App Store signing...")
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
                emit("Registering bundle ID (platform: \(bundleIdPlatform))...")
                let appName = bundleId.split(separator: ".").last.map(String.init) ?? bundleId
                let created = try await ascService.registerBundleId(identifier: bundleId, name: appName, platform: bundleIdPlatform)
                emit("Registered bundle ID: \(created.id)")
                bundleIdResourceId = created.id
            }
            state.bundleIdResourceId = bundleIdResourceId
            try saveSigningState(state, bundleId: bundleId)
        }

        // 2. Distribution certificate
        // For macOS: prefer existing universal DISTRIBUTION cert (Apple Distribution) since
        // Xcode uses it by default. Only fall back to MAC_APP_DISTRIBUTION if none found.
        let certificateId: String
        if let existing = state.certificateId {
            emit("\(certType) certificate already configured: \(existing)")
            certificateId = existing
        } else {
            var foundCert: ASCCertificate?

            // For macOS, first check for universal DISTRIBUTION cert (Apple Distribution)
            if isMacOS {
                emit("Checking DISTRIBUTION (Apple Distribution) certificates...")
                let universalCerts = try await ascService.fetchCertificates(type: "DISTRIBUTION")
                foundCert = universalCerts.first
                if let cert = foundCert {
                    emit("Using existing Apple Distribution certificate: \(cert.attributes.displayName ?? cert.id)")
                }
            }

            // Check platform-specific cert type
            if foundCert == nil {
                emit("Checking \(certType) certificates...")
                let certs = try await ascService.fetchCertificates(type: certType)
                foundCert = certs.first
                if let cert = foundCert {
                    emit("Using existing certificate: \(cert.attributes.displayName ?? cert.id)")
                }
            }

            if let cert = foundCert {
                certificateId = cert.id
            } else {
                emit("No distribution certificate found. Creating \(certType)...")
                certificateId = try await createAndImportCertificate(
                    bundleId: bundleId,
                    certType: certType,
                    filePrefix: "dist",
                    csrCN: isMacOS ? "Mac App Distribution" : "Blitz Distribution",
                    ascService: ascService,
                    emit: emit
                )
            }
            state.certificateId = certificateId
            try saveSigningState(state, bundleId: bundleId)
        }

        // 2b. macOS Installer certificate (for signing .pkg)
        if isMacOS {
            if let existing = state.installerCertificateId {
                emit("MAC_INSTALLER_DISTRIBUTION certificate already configured: \(existing)")
            } else {
                emit("Checking MAC_INSTALLER_DISTRIBUTION certificates...")
                let certs = try await ascService.fetchCertificates(type: "MAC_INSTALLER_DISTRIBUTION")
                if let cert = certs.first {
                    emit("Using existing installer certificate: \(cert.attributes.displayName ?? cert.id)")
                    state.installerCertificateId = cert.id
                } else {
                    emit("No MAC_INSTALLER_DISTRIBUTION certificate found. Creating one...")
                    let installerCertId = try await createAndImportCertificate(
                        bundleId: bundleId,
                        certType: "MAC_INSTALLER_DISTRIBUTION",
                        filePrefix: "installer",
                        csrCN: "Mac Installer Distribution",
                        ascService: ascService,
                        emit: emit
                    )
                    state.installerCertificateId = installerCertId
                }
                try saveSigningState(state, bundleId: bundleId)
            }
        }

        // 3. Provisioning profile
        let profileUUID: String
        let profileExt = isMacOS ? "provisionprofile" : "mobileprovision"
        let profilesDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/MobileDevice/Provisioning Profiles")

        if let existing = state.profileUUID,
           fm.fileExists(atPath: profilesDir.appendingPathComponent("\(existing).\(profileExt)").path) {
            emit("Provisioning profile already installed: \(existing)")
            profileUUID = existing

            // Recover team ID from installed profile if missing
            if state.teamId == nil && teamId == nil {
                let profilePath = profilesDir.appendingPathComponent("\(existing).\(profileExt)").path
                if let extractedTeamId = Self.extractTeamId(from: profilePath) {
                    state.teamId = extractedTeamId
                    try saveSigningState(state, bundleId: bundleId)
                    emit("Extracted team ID from installed profile: \(extractedTeamId)")
                }
            }
        } else {
            if state.profileUUID != nil {
                emit("Provisioning profile missing from disk, re-downloading...")
                state.profileUUID = nil
                state.profileName = nil
                try saveSigningState(state, bundleId: bundleId)
            }
            emit("Creating provisioning profile (type: \(profileType))...")
            let profileName = "\(bundleId) \(isMacOS ? "Mac " : "")App Store"
            let profile: ASCProfile
            do {
                profile = try await ascService.createProfile(
                    name: profileName,
                    bundleIdResourceId: bundleIdResourceId,
                    certificateId: certificateId,
                    profileType: profileType
                )
            } catch let ascErr as ASCError where ascErr.isConflict {
                // Duplicate profile name — delete existing and retry
                emit("Profile name conflict. Deleting existing duplicates...")
                let existing = try await ascService.fetchProfiles(name: profileName)
                for old in existing {
                    try? await ascService.deleteProfile(id: old.id)
                    emit("Deleted duplicate profile: \(old.id)")
                }
                profile = try await ascService.createProfile(
                    name: profileName,
                    bundleIdResourceId: bundleIdResourceId,
                    certificateId: certificateId,
                    profileType: profileType
                )
            }
            emit("Created profile: \(profile.attributes.name)")

            // Decode and install the profile
            if let profileBase64 = profile.attributes.profileContent,
               let profileData = Data(base64Encoded: profileBase64) {

                // Extract UUID from the profile plist
                let uuid = profile.attributes.uuid ?? UUID().uuidString

                try fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
                let profilePath = profilesDir.appendingPathComponent("\(uuid).\(profileExt)")
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
            installerCertificateId: state.installerCertificateId,
            profileUUID: profileUUID,
            teamId: resolvedTeamId,
            log: log
        )
    }

    /// Generate a CSR, create a certificate via ASC API, and import to keychain.
    private func createAndImportCertificate(
        bundleId: String,
        certType: String,
        filePrefix: String,
        csrCN: String,
        ascService: AppStoreConnectService,
        emit: (String) -> Void
    ) async throws -> String {
        let signingDir = BlitzPaths.signing(bundleId: bundleId)
        try fm.createDirectory(at: signingDir, withIntermediateDirectories: true)

        let keyPath = signingDir.appendingPathComponent("\(filePrefix).key").path
        let csrPath = signingDir.appendingPathComponent("\(filePrefix).csr").path

        // Generate private key
        try await ProcessRunner.run("openssl", arguments: [
            "genrsa", "-out", keyPath, "2048"
        ], timeout: 30)
        emit("Generated RSA private key (\(filePrefix))")
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath)

        // Generate CSR
        try await ProcessRunner.run("openssl", arguments: [
            "req", "-new", "-key", keyPath, "-out", csrPath,
            "-subj", "/CN=\(csrCN)/O=Blitz/C=US"
        ], timeout: 30)
        let csrContent = try String(contentsOfFile: csrPath, encoding: .utf8)
        emit("Generated CSR (\(filePrefix))")

        // Create certificate via API
        let cert = try await ascService.createCertificate(csrContent: csrContent, type: certType)
        emit("Created \(certType) certificate: \(cert.id)")

        // Decode certificate content and import to keychain
        if let certBase64 = cert.attributes.certificateContent,
           let certData = Data(base64Encoded: certBase64) {
            let derPath = signingDir.appendingPathComponent("\(filePrefix).cer").path
            try certData.write(to: URL(fileURLWithPath: derPath))

            // Convert DER to PEM
            let pemPath = signingDir.appendingPathComponent("\(filePrefix).pem").path
            try await ProcessRunner.run("openssl", arguments: [
                "x509", "-inform", "DER", "-in", derPath, "-out", pemPath
            ], timeout: 30)

            // Create p12 for keychain import — use legacy algorithms (PBE-SHA1-3DES)
            // and a real password; OpenSSL 3.x defaults to AES-256-CBC which macOS
            // security cannot import, and empty passwords also fail.
            let p12Path = signingDir.appendingPathComponent("\(filePrefix).p12").path
            let p12Pass = "blitz-\(bundleId.hashValue & 0x7FFFFFFF)"
            try await ProcessRunner.run("openssl", arguments: [
                "pkcs12", "-export",
                "-inkey", keyPath, "-in", pemPath,
                "-out", p12Path, "-passout", "pass:\(p12Pass)",
                "-certpbe", "PBE-SHA1-3DES",
                "-keypbe", "PBE-SHA1-3DES",
                "-macalg", "SHA1"
            ], timeout: 30)

            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12Path)

            // Import to keychain
            try await ProcessRunner.run("security", arguments: [
                "import", p12Path, "-k",
                fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains/login.keychain-db").path,
                "-P", p12Pass, "-T", "/usr/bin/codesign",
                "-T", "/usr/bin/security"
            ], timeout: 30)
            emit("Imported \(certType) certificate to keychain")
        }

        return cert.id
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
    /// Public so it can be called from MCPExecutor when the user changes bundle ID.
    func updateBundleIdInPbxproj(projectPath: String, bundleId: String) {
        let projectURL = URL(fileURLWithPath: projectPath).resolvingSymlinksInPath()
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
        let projectURL = URL(fileURLWithPath: projectPath).resolvingSymlinksInPath()
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
        let ipaPath: String  // .ipa for iOS, .pkg for macOS
        let archivePath: String
        let log: [String]
    }

    func buildIPA(
        projectPath: String,
        bundleId: String,
        teamId: String,
        scheme: String?,
        configuration: String?,
        platform: ProjectPlatform = .iOS,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> BuildResult {
        var log: [String] = []

        func emit(_ msg: String) {
            log.append(msg)
            onProgress(msg)
        }

        let projectURL = URL(fileURLWithPath: projectPath).resolvingSymlinksInPath().resolvingSymlinksInPath()

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

        // Load signing state so we can use manual distribution signing in both archive + export
        let signingState = loadSigningState(bundleId: bundleId)
        let profileRef = signingState.profileName ?? signingState.profileUUID ?? ""

        guard !profileRef.isEmpty else {
            throw ProcessRunner.ProcessError(
                command: "app_store_build",
                exitCode: -1,
                stderr: "No provisioning profile found for \(bundleId). Run app_store_setup_signing first (it will auto-generate a distribution certificate and profile)."
            )
        }

        let isMac = platform == .macOS

        // Archive with automatic/dev signing — no signing overrides on the command line,
        // because xcodebuild build settings apply globally to ALL targets including SPM
        // dependencies, which don't support provisioning profiles or manual signing.
        // The exportArchive step below re-signs with distribution cert + profile.
        let archivePath = NSTemporaryDirectory() + "BlitzArchive-\(Int(Date().timeIntervalSince1970)).xcarchive"
        let destination = isMac ? "generic/platform=macOS" : "generic/platform=iOS"
        let archiveArgs = [
            useWorkspace ? "-workspace" : "-project",
            buildTarget,
            "-scheme", resolvedScheme,
            "-configuration", config,
            "-destination", destination,
            "-archivePath", archivePath,
            "archive",
            "DEVELOPMENT_TEAM=\(teamId)",
            "PRODUCT_BUNDLE_IDENTIFIER=\(bundleId)"
        ]

        let archiveOutput = ProcessOutputCollector()
        let managed = ProcessRunner.stream(
            "xcodebuild",
            arguments: archiveArgs,
            currentDirectory: xcodeDir,
            onStdout: { line in
                onProgress(line)
                archiveOutput.appendStdout(line)
            },
            onStderr: { line in
                onProgress(line)
                archiveOutput.appendStderr(line)
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
            let stderrSummary = archiveOutput.summary
            throw ProcessRunner.ProcessError(
                command: "xcodebuild archive",
                exitCode: managed.process.terminationStatus,
                stderr: stderrSummary.isEmpty ? "Archive failed with exit code \(managed.process.terminationStatus)" : stderrSummary
            )
        }
        emit("Archive succeeded: \(archivePath)")

        // Generate ExportOptions.plist
        // app-store-connect produces a .pkg for macOS; app-store produces an .ipa for iOS
        let exportOptionsPath = NSTemporaryDirectory() + "ExportOptions-\(Int(Date().timeIntervalSince1970)).plist"
        var exportOptions: [String: Any] = [
            "method": isMac ? "app-store-connect" : "app-store",
            "teamID": teamId,
            "signingStyle": "manual",
            "signingCertificate": "Apple Distribution",
            "uploadSymbols": true
        ]
        if !profileRef.isEmpty {
            exportOptions["provisioningProfiles"] = [bundleId: profileRef]
        }
        if isMac {
            // installerSigningCertificate tells xcodebuild to produce a signed .pkg
            exportOptions["installerSigningCertificate"] = "3rd Party Mac Developer Installer"
        }
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: exportOptions,
            format: .xml,
            options: 0
        )
        try plistData.write(to: URL(fileURLWithPath: exportOptionsPath))
        emit("Generated ExportOptions.plist")

        // Export IPA
        let exportPath = NSTemporaryDirectory() + "BlitzExport-\(Int(Date().timeIntervalSince1970))"
        let exportOutput = ProcessOutputCollector()
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
            onStdout: { line in
                onProgress(line)
                exportOutput.appendStdout(line)
            },
            onStderr: { line in
                onProgress(line)
                exportOutput.appendStderr(line)
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
            var stderrSummary = exportOutput.summary

            // Extract real error from IDEDistribution log if available
            // xcodebuild prints "Created bundle at path <log_path>" on export failure
            if let logDir = exportOutput.lastLogBundlePath {
                let errorLogPath = logDir + "/IDEDistribution.standard-log.txt"
                if let logContent = try? String(contentsOfFile: errorLogPath, encoding: .utf8) {
                    // Extract error lines from the log
                    let errorLines = logContent.components(separatedBy: "\n")
                        .filter {
                            let lowercased = $0.lowercased()
                            return lowercased.contains("error:")
                                || lowercased.contains("error domain")
                                || lowercased.contains("no profiles")
                                || lowercased.contains("doesn't match")
                                || lowercased.contains("provisioning")
                                || lowercased.contains("asset catalog")
                                || lowercased.contains("appicon")
                                || lowercased.contains(".appiconset")
                        }
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

        // Find the exported artifact (.pkg for macOS, .ipa for iOS)
        let exportedFiles = try fm.contentsOfDirectory(at: URL(fileURLWithPath: exportPath),
                                                        includingPropertiesForKeys: nil)
        let expectedExt = isMac ? "pkg" : "ipa"
        guard let artifactURL = exportedFiles.first(where: { $0.pathExtension == expectedExt }) else {
            throw ProcessRunner.ProcessError(
                command: "xcodebuild -exportArchive",
                exitCode: -1,
                stderr: "No .\(expectedExt) found in export directory: \(exportPath)"
            )
        }

        emit("\(expectedExt.uppercased()) exported: \(artifactURL.path)")

        return BuildResult(
            ipaPath: artifactURL.path,
            archivePath: archivePath,
            log: log
        )
    }

    // MARK: - Upload to TestFlight

    struct HelperBuildUploadResult: Decodable {
        let uploadId: String
        let fileId: String
        let fileName: String?
        let fileSize: Int64?
        let uploaded: Bool?
    }

    struct UploadResult {
        let buildVersion: String?
        let processingState: String?
        let uploadId: String?
        let fileId: String?
        let uploadCommitted: Bool
        let log: [String]
    }

    static func buildsUploadCommandArguments(
        appId: String,
        artifactPath: String,
        platform: ProjectPlatform,
        skipPolling: Bool
    ) -> [String] {
        let isMacArtifact = platform == .macOS
            || URL(fileURLWithPath: artifactPath).pathExtension.lowercased() == "pkg"
        var args = ["builds", "upload", "--app", appId]
        if isMacArtifact {
            args += ["--pkg", artifactPath, "--platform", "MAC_OS"]
        } else {
            args += ["--ipa", artifactPath, "--platform", "IOS"]
        }
        if skipPolling {
            args += ["--verify-timeout", helperUploadVerifyTimeout]
        } else {
            args.append("--wait")
        }
        args += ["--output", "json"]
        return args
    }

    static func parseBuildUploadCLIResult(from stdout: String) throws -> HelperBuildUploadResult {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProcessRunner.ProcessError(
                command: "asc builds upload",
                exitCode: -1,
                stderr: "ASC helper returned no JSON output for the build upload."
            )
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw ProcessRunner.ProcessError(
                command: "asc builds upload",
                exitCode: -1,
                stderr: "ASC helper returned non-UTF8 build upload output."
            )
        }
        do {
            return try JSONDecoder().decode(HelperBuildUploadResult.self, from: data)
        } catch {
            throw ProcessRunner.ProcessError(
                command: "asc builds upload",
                exitCode: -1,
                stderr: "Failed to decode ASC helper build upload output: \(error.localizedDescription)"
            )
        }
    }

    static func validatedBuildUploadCLIResult(from stdout: String) throws -> HelperBuildUploadResult {
        let result = try parseBuildUploadCLIResult(from: stdout)
        guard result.uploaded == true else {
            throw ProcessRunner.ProcessError(
                command: "asc builds upload",
                exitCode: -1,
                stderr: "App Store Connect reserved upload \(result.uploadId), but file \(result.fileId) was not marked uploaded."
            )
        }
        return result
    }

    func uploadToTestFlight(
        ipaPath: String,
        keyId: String,
        issuerId: String,
        privateKeyPEM: String,
        appId: String?,
        ascService: AppStoreConnectService?,
        skipPolling: Bool,
        platform: ProjectPlatform = .iOS,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> UploadResult {
        var log: [String] = []

        func emit(_ msg: String) {
            log.append(msg)
            onProgress(msg)
        }

        if let appId, let ascService {
            emit("Uploading \(platform == .macOS ? "PKG" : "IPA") to App Store Connect...")
            let cliArgs = Self.buildsUploadCommandArguments(
                appId: appId,
                artifactPath: ipaPath,
                platform: platform,
                skipPolling: skipPolling
            )
            let cliResult = try await ascService.cliExec(args: cliArgs)

            let stderrLines = cliResult.stderr
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            log.append(contentsOf: stderrLines)

            guard cliResult.exitCode == 0 else {
                let stderrSummary = stderrLines.isEmpty
                    ? cliResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    : stderrLines.joined(separator: "\n")
                throw ProcessRunner.ProcessError(
                    command: "asc builds upload",
                    exitCode: Int32(cliResult.exitCode),
                    stderr: stderrSummary.isEmpty
                        ? "Build upload failed with exit code \(cliResult.exitCode)"
                        : stderrSummary
                )
            }

            let helperResult = try Self.validatedBuildUploadCLIResult(from: cliResult.stdout)

            emit("Upload committed in App Store Connect.")
            return UploadResult(
                buildVersion: nil,
                processingState: skipPolling ? "UPLOAD_COMMITTED" : nil,
                uploadId: helperResult.uploadId,
                fileId: helperResult.fileId,
                uploadCommitted: true,
                log: log
            )
        }

        // Place .p8 key for altool/notarytool
        let keyDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".appstoreconnect/private_keys")
        try fm.createDirectory(at: keyDir, withIntermediateDirectories: true)
        let keyPath = keyDir.appendingPathComponent("AuthKey_\(keyId).p8")
        try privateKeyPEM.write(to: keyPath, atomically: true, encoding: .utf8)
        emit("API key placed at \(keyPath.path)")

        // Upload using xcrun altool
        let platformType = platform == .macOS ? "osx" : "ios"
        emit("Uploading \(platform == .macOS ? "PKG" : "IPA") to App Store Connect...")
        let uploadOutput = ProcessOutputCollector()
        let uploadManaged = ProcessRunner.stream(
            "xcrun",
            arguments: [
                "altool", "--upload-app",
                "-f", ipaPath,
                "-t", platformType,
                "--apiKey", keyId,
                "--apiIssuer", issuerId
            ],
            onStdout: { line in
                onProgress(line)
                uploadOutput.appendStdout(line)
            },
            onStderr: { line in
                onProgress(line)
                uploadOutput.appendStderr(line)
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
            let stderrSummary = uploadOutput.summary
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
                            uploadId: nil,
                            fileId: nil,
                            uploadCommitted: true,
                            log: log
                        )
                    } else if state == "INVALID" {
                        emit("Build processing failed with INVALID state")
                        return UploadResult(
                            buildVersion: build.attributes.version,
                            processingState: state,
                            uploadId: nil,
                            fileId: nil,
                            uploadCommitted: true,
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
            uploadId: nil,
            fileId: nil,
            uploadCommitted: true,
            log: log
        )
    }
}

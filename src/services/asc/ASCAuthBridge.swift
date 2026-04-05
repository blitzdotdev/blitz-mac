import Foundation

struct ASCAuthBridge {
    static let managedProfileName = "BlitzKey"
    private static let cliSubprocessModeArg = "__ascd_run_cli__"

    let blitzRoot: URL
    let fileManager: FileManager
    private let bundledASCDPathProvider: () -> String?

    init(
        blitzRoot: URL = BlitzPaths.root,
        fileManager: FileManager = .default,
        bundledASCDPathProvider: @escaping () -> String? = {
            ASCAuthBridge.resolveBundledASCDPath(
                fileManager: .default,
                environment: ProcessInfo.processInfo.environment
            )
        }
    ) {
        self.blitzRoot = blitzRoot
        self.fileManager = fileManager
        self.bundledASCDPathProvider = bundledASCDPathProvider
    }

    var bridgeDirectory: URL {
        blitzRoot.appendingPathComponent("asc-agent", isDirectory: true)
    }

    var binDirectory: URL {
        blitzRoot.appendingPathComponent("bin", isDirectory: true)
    }

    var configURL: URL {
        bridgeDirectory.appendingPathComponent("config.json")
    }

    var privateKeyURL: URL {
        bridgeDirectory.appendingPathComponent("AuthKey_\(Self.managedProfileName).p8")
    }

    var webSessionURL: URL {
        bridgeDirectory.appendingPathComponent("web-session.json")
    }

    var ascWrapperURL: URL {
        binDirectory.appendingPathComponent("asc")
    }

    var ascdShimURL: URL {
        binDirectory.appendingPathComponent("ascd")
    }

    func environmentOverrides(
        forLaunchPath launchPath: String?,
        baseEnvironment: [String: String]? = nil
    ) -> [String: String] {
        guard shouldInjectEnvironment(forLaunchPath: launchPath) else {
            return [:]
        }

        prepareEnvironment()
        let currentPath = baseEnvironment?["PATH"]
            ?? ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return [
            "PATH": "\(binDirectory.path):\(currentPath)",
        ]
    }

    func shellExportCommands(forLaunchPath launchPath: String?) -> [String] {
        guard shouldInjectEnvironment(forLaunchPath: launchPath) else {
            return []
        }

        prepareEnvironment()
        return [
            "export PATH=\(shellQuote(binDirectory.path)):\"$PATH\"",
        ]
    }

    func syncStoredCredentials() throws {
        try syncCredentials(ASCCredentials.load())
    }

    func syncCredentials(_ credentials: ASCCredentials?) throws {
        guard let credentials else {
            cleanup()
            return
        }

        try ensureBridgeDirectory()
        try writePrivateKey(credentials.privateKey)
        try writeConfig(credentials: credentials)
    }

    /// Write web session data to a file so CLI scripts can read it without Keychain popups.
    func syncWebSession(_ data: Data) throws {
        try ensureBridgeDirectory()
        try data.write(to: webSessionURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: webSessionURL.path)
    }

    func removeWebSession() {
        try? fileManager.removeItem(at: webSessionURL)
    }

    func cleanup() {
        try? fileManager.removeItem(at: configURL)
        try? fileManager.removeItem(at: privateKeyURL)
    }

    func installCLIShims() throws {
        let bundledASCDPath = bundledASCDPathProvider()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try ensureBinDirectory()
        try installASCDShim(from: bundledASCDPath)
        try ensureCLIWrapper()
    }

    private func prepareEnvironment() {
        try? syncStoredCredentials()
        try? installCLIShims()
    }

    private func ensureBridgeDirectory() throws {
        try fileManager.createDirectory(
            at: bridgeDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bridgeDirectory.path)
    }

    private func writePrivateKey(_ privateKey: String) throws {
        let data = Data(privateKey.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        try data.write(to: privateKeyURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKeyURL.path)
    }

    private func writeConfig(credentials: ASCCredentials) throws {
        let config = ManagedConfig(
            keyID: credentials.keyId,
            issuerID: credentials.issuerId,
            privateKeyPath: privateKeyURL.path,
            defaultKeyName: Self.managedProfileName,
            keys: [
                ManagedCredential(
                    name: Self.managedProfileName,
                    keyID: credentials.keyId,
                    issuerID: credentials.issuerId,
                    privateKeyPath: privateKeyURL.path
                )
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: configURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    private func ensureBinDirectory() throws {
        try fileManager.createDirectory(
            at: binDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binDirectory.path)
    }

    private func installASCDShim(from bundledASCDPath: String?) throws {
        guard let bundledASCDPath,
              !bundledASCDPath.isEmpty,
              fileManager.isExecutableFile(atPath: bundledASCDPath) else {
            guard fileManager.isExecutableFile(atPath: ascdShimURL.path) else {
                throw NSError(
                    domain: "ASCAuthBridge",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Bundled ascd helper is unavailable."]
                )
            }
            return
        }

        let tempURL = binDirectory.appendingPathComponent("ascd.tmp.\(UUID().uuidString)")
        try? fileManager.removeItem(at: tempURL)
        try fileManager.copyItem(at: URL(fileURLWithPath: bundledASCDPath), to: tempURL)
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempURL.path)
        try? fileManager.removeItem(at: ascdShimURL)
        try fileManager.moveItem(at: tempURL, to: ascdShimURL)
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ascdShimURL.path)
    }

    private func ensureCLIWrapper() throws {
        let script = wrapperScript()
        try script.write(to: ascWrapperURL, atomically: true, encoding: .utf8)
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ascWrapperURL.path)
    }

    private func wrapperScript() -> String {
        return """
        #!/bin/sh
        set -eu

        SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
        ASCD_PATH="${SELF_DIR}/ascd"

        if [ ! -x "${ASCD_PATH}" ]; then
            echo "asc: Blitz helper not found at ${ASCD_PATH}. Start Blitz first." >&2
            exit 1
        fi

        if [ -z "${ASC_CONFIG_PATH:-}" ]; then
            export ASC_CONFIG_PATH=\(shellQuote(configURL.path))
        fi

        if [ -z "${ASC_BYPASS_KEYCHAIN:-}" ]; then
            export ASC_BYPASS_KEYCHAIN='1'
        fi

        exec "${ASCD_PATH}" \(Self.cliSubprocessModeArg) "$@"
        """
    }

    private func shouldInjectEnvironment(forLaunchPath launchPath: String?) -> Bool {
        guard let launchPath else { return false }

        let normalizedPath = URL(fileURLWithPath: launchPath).standardizedFileURL.path
        let projectsRoot = blitzRoot.appendingPathComponent("projects", isDirectory: true).standardizedFileURL.path
        let mcpsRoot = blitzRoot.appendingPathComponent("mcps", isDirectory: true).standardizedFileURL.path

        return normalizedPath == projectsRoot
            || normalizedPath.hasPrefix(projectsRoot + "/")
            || normalizedPath == mcpsRoot
            || normalizedPath.hasPrefix(mcpsRoot + "/")
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func resolveBundledASCDPath(
        fileManager: FileManager,
        environment: [String: String]
    ) -> String? {
        var candidates: [String] = []
        var seen = Set<String>()

        func appendCandidate(_ rawValue: String?) {
            guard let rawValue else { return }
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            let expanded = NSString(string: trimmed).expandingTildeInPath
            let normalized: String
            if expanded.hasPrefix("/") {
                normalized = URL(fileURLWithPath: expanded).standardizedFileURL.path
            } else {
                normalized = expanded
            }

            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return }
            candidates.append(normalized)
        }

        appendCandidate(environment["BLITZ_ASCD_PATH"])
        appendCandidate(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ascd").path)
        appendCandidate(
            Bundle.main.executableURL?
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Helpers/ascd").path
        )
        appendCandidate(
            Bundle.main.privateFrameworksURL?
                .deletingLastPathComponent()
                .appendingPathComponent("Helpers/ascd").path
        )

        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0) })
    }
}

private struct ManagedConfig: Codable {
    let keyID: String
    let issuerID: String
    let privateKeyPath: String
    let defaultKeyName: String
    let keys: [ManagedCredential]

    private enum CodingKeys: String, CodingKey {
        case keyID = "key_id"
        case issuerID = "issuer_id"
        case privateKeyPath = "private_key_path"
        case defaultKeyName = "default_key_name"
        case keys
    }
}

private struct ManagedCredential: Codable {
    let name: String
    let keyID: String
    let issuerID: String
    let privateKeyPath: String

    private enum CodingKeys: String, CodingKey {
        case name
        case keyID = "key_id"
        case issuerID = "issuer_id"
        case privateKeyPath = "private_key_path"
    }
}

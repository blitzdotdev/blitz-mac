import AppKit
import Foundation

/// Handles checking for updates, downloading, and installing them.
/// Mirrors the Tauri updater approach: fetch latest.json, download .app.zip,
/// replace /Applications/Blitz.app via osascript, relaunch.
@MainActor
@Observable
final class AutoUpdateManager {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, releaseNotes: String)
        case downloading(percent: Int)
        case installing
        case failed(String)
    }

    var state: State = .idle

    var isUpdateAvailable: Bool {
        if case .available = state { return true }
        return false
    }

    /// True when the update UI should cover the entire welcome window.
    var showsFullScreenOverlay: Bool {
        switch state {
        case .idle, .checking, .upToDate: return false
        default: return true
        }
    }

    private var latestVersion: String?
    private var downloadURL: String?
    private var downloadFilename: String?

    private static let releasesURL = "https://api.github.com/repos/blitzdotdev/blitz-mac/releases/latest"
    //private static let releasesURL = "https://api.github.com/repos/pythonlearner1025/blitz-mac-preflight/releases/latest"

    /// Current app version from Info.plist (falls back to "0.0.0" in dev builds).
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // MARK: - Check

    func checkForUpdate() async {
        state = .checking

        // TODO - remove before release: DEBUG use local zip instead of fetching from GitHub
        // let debugLocalZip = "SET_TO_YOUR_LOCAL_PATH/Blitz.app.zip"
        // latestVersion = "1.0.30"
        // downloadURL = "file://\(debugLocalZip)"
        // downloadFilename = "Blitz.app.zip"
        // state = .available(version: "1.0.30", releaseNotes: "Debug test update")
        // return
        // END DEBUG

        do {
            var request = URLRequest(url: URL(string: Self.releasesURL)!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]] else {
                state = .idle
                return
            }

            let remoteVersion = tagName.replacingOccurrences(of: "v", with: "")

            // Prefer .app.zip for auto-updates (no admin password prompt);
            // fall back to .pkg if zip isn't available
            let zipAsset = assets.first { ($0["name"] as? String)?.hasSuffix(".app.zip") == true }
            let pkgAsset = assets.first { ($0["name"] as? String)?.hasSuffix(".pkg") == true }
            guard let asset = zipAsset ?? pkgAsset,
                  let downloadUrl = asset["browser_download_url"] as? String,
                  let filename = asset["name"] as? String else {
                state = .idle
                return
            }

            guard Self.isNewer(remote: remoteVersion, current: currentVersion) else {
                print("[AutoUpdate] Up to date (current: \(currentVersion), remote: \(remoteVersion))")
                state = .upToDate
                return
            }

            print("[AutoUpdate] Update available: \(currentVersion) -> \(remoteVersion)")
            latestVersion = remoteVersion
            downloadURL = downloadUrl
            downloadFilename = filename

            let notes = await Self.fetchChangelogNotes(for: remoteVersion)
            state = .available(version: remoteVersion, releaseNotes: notes)
        } catch {
            print("[AutoUpdate] Check failed: \(error)")
            state = .idle
        }
    }

    // MARK: - Download & Install

    func performUpdate() async {
        guard let url = downloadURL, let filename = downloadFilename else { return }

        state = .downloading(percent: -1)

        do {
            let downloadedPath = try await downloadApp(url: url, filename: filename)
            state = .installing
            if filename.hasSuffix(".pkg") {
                try await installPkg(pkgPath: downloadedPath)
            } else {
                try await installApp(zipPath: downloadedPath)
            }
            // If we get here, the app is about to relaunch
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func dismiss() {
        state = .idle
    }

    // MARK: - Private

    private func downloadApp(url: String, filename: String) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        // Remove stale download
        try? FileManager.default.removeItem(at: destination)

        let request = URLRequest(url: URL(string: url)!)
        let (data, _) = try await URLSession.shared.data(for: request)

        try data.write(to: destination)
        print("[AutoUpdate] Downloaded \(data.count) bytes to \(destination.path)")
        return destination
    }

    private func installPkg(pkgPath: URL) async throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let pkg = pkgPath.path.replacingOccurrences(of: "'", with: "'\\''")

        let installScript = """
        do shell script "installer -pkg '\(pkg)' -target / 2>&1" with administrator privileges
        """

        let relaunchScript = """
        do shell script "(while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open /Applications/Blitz.app) &>/dev/null &"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", installScript, "-e", relaunchScript]
        process.standardOutput = nil
        process.standardError = nil

        try process.run()

        // Wait off the main thread so the runloop stays responsive
        let status = await Task.detached { () -> Int32 in
            process.waitUntilExit()
            return process.terminationStatus
        }.value

        try? FileManager.default.removeItem(at: pkgPath)

        guard status == 0 else {
            throw UpdateError(message: "Installation failed (exit code \(status))")
        }

        terminateApp()
    }

    private func installApp(zipPath: URL) async throws {
        let pid = ProcessInfo.processInfo.processIdentifier

        // AppleScript statement 1: unzip, replace app, then run postinstall.
        // The PKG postinstall chowns Blitz.app to the current user, so no admin needed.
        // We intentionally skip preinstall during .app.zip updates because those
        // checks are for first-time setup and can trigger heavyweight Xcode/runtime work.
        // The embedded postinstall script remains available at Contents/Resources/pkg-scripts/.
        let installScript = Self.appUpdateInstallScript(zipPath: zipPath)

        // AppleScript statement 2: background wait-for-exit + relaunch
        let relaunchScript = """
        do shell script "(while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open /Applications/Blitz.app) &>/dev/null &"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", installScript, "-e", relaunchScript]
        process.standardOutput = nil
        process.standardError = nil

        try process.run()

        // Wait off the main thread so the runloop stays responsive
        let status = await Task.detached { () -> Int32 in
            process.waitUntilExit()
            return process.terminationStatus
        }.value

        guard status == 0 else {
            throw UpdateError(message: "Installation failed (exit code \(status))")
        }

        terminateApp()
    }

    /// Force-quit the app so the background relaunch script can kick in.
    /// Uses exit(0) as a fallback in case terminate(nil) is blocked by the app delegate.
    private func terminateApp() {
        NSApplication.shared.terminate(nil)
        // If terminate didn't exit (e.g. delegate intercepted it), force quit after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            exit(0)
        }
    }

    /// Fetches CHANGELOG.md from the repo and extracts the notes for the given version.
    private static func fetchChangelogNotes(for version: String) async -> String {
        let rawURL = "https://raw.githubusercontent.com/blitzdotdev/blitz-mac/master/CHANGELOG.md"
        do {
            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: URL(string: rawURL)!))
            guard let content = String(data: data, encoding: .utf8) else { return "" }
            return parseChangelog(content, version: version)
        } catch {
            print("[AutoUpdate] Failed to fetch CHANGELOG.md: \(error)")
            return ""
        }
    }

    /// Extracts bullet points under the `## <version>` heading from a changelog string.
    private static func parseChangelog(_ content: String, version: String) -> String {
        let lines = content.components(separatedBy: "\n")
        var capturing = false
        var notes: [String] = []

        for line in lines {
            if line.hasPrefix("## ") {
                if capturing { break }
                let heading = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                if heading == version {
                    capturing = true
                }
            } else if capturing {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    notes.append(trimmed)
                }
            }
        }

        return notes.joined(separator: "\n")
    }

    /// Simple semver comparison (major.minor.patch).
    private static func isNewer(remote: String, current: String) -> Bool {
        let parse = { (v: String) -> [Int] in
            v.trimmingCharacters(in: .whitespaces)
             .replacingOccurrences(of: "v", with: "")
             .split(separator: ".")
             .compactMap { Int($0) }
        }
        let r = parse(remote)
        let c = parse(current)
        guard r.count >= 3, c.count >= 3 else { return false }
        if r[0] != c[0] { return r[0] > c[0] }
        if r[1] != c[1] { return r[1] > c[1] }
        return r[2] > c[2]
    }

    struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func appUpdateInstallScript(zipPath: URL) -> String {
        let zip = shellLiteral(zipPath.path)
        return """
        do shell script "set -eu; \
        TMPZIP=\(zip); \
        UPDATE_LOG='/tmp/blitz_install.log'; \
        UNZIP_DIR=$(mktemp -d); \
        cleanup() { rm -rf \\"$UNZIP_DIR\\" \\"$TMPZIP\\"; }; \
        trap cleanup EXIT; \
        unzip -qo \\"$TMPZIP\\" -d \\"$UNZIP_DIR\\"; \
        APP_SRC=$(find \\"$UNZIP_DIR\\" -maxdepth 1 -name '*.app' -type d | head -1); \
        if [ -z \\"$APP_SRC\\" ]; then echo 'Update failed: extracted app not found' >> \\"$UPDATE_LOG\\"; exit 1; fi; \
        BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \\"$APP_SRC/Contents/Info.plist\\" 2>> \\"$UPDATE_LOG\\" || true); \
        if [ \\"$BUNDLE_ID\\" != 'com.blitz.macos' ]; then echo 'Update failed: unexpected bundle identifier' >> \\"$UPDATE_LOG\\"; exit 1; fi; \
        if [ ! -x \\"$APP_SRC/Contents/Helpers/ascd\\" ]; then echo 'Update failed: bundled ascd helper missing' >> \\"$UPDATE_LOG\\"; exit 1; fi; \
        rm -rf /Applications/Blitz.app; \
        mv \\"$APP_SRC\\" /Applications/Blitz.app; \
        POSTINSTALL='/Applications/Blitz.app/Contents/Resources/pkg-scripts/postinstall'; \
        if [ -x \\"$POSTINSTALL\\" ]; then BLITZ_UPDATE_CONTEXT='auto-update' \\"$POSTINSTALL\\" '' '' '/' >> \\"$UPDATE_LOG\\" 2>&1; fi"
        """
    }

    private static func shellLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

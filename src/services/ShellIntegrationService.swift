import Darwin
import Foundation

struct ShellIntegrationService {
    enum ShellKind: Equatable {
        case zsh
        case bash
        case unsupported(String?)

        var displayName: String {
            switch self {
            case .zsh:
                return "zsh"
            case .bash:
                return "bash"
            case .unsupported(let path):
                let shellName = URL(fileURLWithPath: path ?? "").lastPathComponent
                return shellName.isEmpty ? "unknown shell" : shellName
            }
        }
    }

    private static let startMarker = "# >>> Blitz shell integration >>>"
    private static let endMarker = "# <<< Blitz shell integration <<<"

    let homeDirectory: URL
    let blitzRoot: URL
    let fileManager: FileManager
    private let authBridge: ASCAuthBridge
    private let loginShellPathProvider: () -> String?

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        blitzRoot: URL = BlitzPaths.root,
        fileManager: FileManager = .default,
        bundledASCDPathProvider: @escaping () -> String? = {
            ASCAuthBridge.resolveBundledASCDPath(
                fileManager: .default,
                environment: ProcessInfo.processInfo.environment
            )
        },
        loginShellPathProvider: @escaping () -> String? = {
            ShellIntegrationService.defaultLoginShellPath()
        }
    ) {
        self.homeDirectory = homeDirectory
        self.blitzRoot = blitzRoot
        self.fileManager = fileManager
        self.authBridge = ASCAuthBridge(
            blitzRoot: blitzRoot,
            fileManager: fileManager,
            bundledASCDPathProvider: bundledASCDPathProvider
        )
        self.loginShellPathProvider = loginShellPathProvider
    }

    var shellKind: ShellKind {
        Self.detectShellKind(loginShellPathProvider())
    }

    var isSupported: Bool {
        targetRCFile != nil
    }

    var targetRCFile: URL? {
        switch shellKind {
        case .zsh:
            return homeDirectory.appendingPathComponent(".zshrc")
        case .bash:
            return homeDirectory.appendingPathComponent(".bashrc")
        case .unsupported:
            return nil
        }
    }

    var targetRCFileLabel: String {
        guard let targetRCFile else { return "unsupported shell" }
        return "~/" + targetRCFile.lastPathComponent
    }

    var initScriptURL: URL {
        blitzRoot.appendingPathComponent("shell/init.sh")
    }

    func sync(enabled: Bool) throws {
        if enabled {
            try install()
        } else {
            try uninstall()
        }
    }

    private func install() throws {
        guard let targetRCFile else {
            throw ShellIntegrationError.unsupportedShell(shellKind.displayName)
        }

        try authBridge.installCLIShims()
        try writeInitScript()
        try upsertManagedBlock(in: targetRCFile)

        for extraRCFile in managedRCFiles where extraRCFile != targetRCFile {
            try removeManagedBlock(from: extraRCFile)
        }
    }

    private func uninstall() throws {
        for rcFile in managedRCFiles {
            try removeManagedBlock(from: rcFile)
        }

        try? fileManager.removeItem(at: initScriptURL)

        let shellDirectory = initScriptURL.deletingLastPathComponent()
        if let contents = try? fileManager.contentsOfDirectory(atPath: shellDirectory.path), contents.isEmpty {
            try? fileManager.removeItem(at: shellDirectory)
        }
    }

    private var managedRCFiles: [URL] {
        [
            homeDirectory.appendingPathComponent(".zshrc"),
            homeDirectory.appendingPathComponent(".bashrc"),
        ]
    }

    private func writeInitScript() throws {
        let shellDirectory = initScriptURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: shellDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shellDirectory.path)

        let binDirectory = blitzRoot.appendingPathComponent("bin").path
        let script = """
        #!/bin/sh
        BLITZ_BIN=\(shellQuote(binDirectory))

        case ":${PATH}:" in
            *":${BLITZ_BIN}:"*) ;;
            *) export PATH="${BLITZ_BIN}:$PATH" ;;
        esac
        """

        try script.write(to: initScriptURL, atomically: true, encoding: .utf8)
        try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: initScriptURL.path)
    }

    private func upsertManagedBlock(in rcFile: URL) throws {
        let existing = (try? String(contentsOf: rcFile, encoding: .utf8)) ?? ""
        let stripped = removingManagedBlock(from: existing).trimmingCharacters(in: .whitespacesAndNewlines)

        let block = managedBlock()
        let newContents: String
        if stripped.isEmpty {
            newContents = block
        } else {
            newContents = stripped + "\n\n" + block
        }

        try newContents.write(to: rcFile, atomically: true, encoding: .utf8)
    }

    private func removeManagedBlock(from rcFile: URL) throws {
        guard fileManager.fileExists(atPath: rcFile.path) else { return }

        let existing = try String(contentsOf: rcFile, encoding: .utf8)
        let stripped = removingManagedBlock(from: existing)
        guard stripped != existing else { return }

        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try "".write(to: rcFile, atomically: true, encoding: .utf8)
        } else {
            try (trimmed + "\n").write(to: rcFile, atomically: true, encoding: .utf8)
        }
    }

    private func managedBlock() -> String {
        """
        \(Self.startMarker)
        if [ -f "$HOME/.blitz/shell/init.sh" ]; then
          . "$HOME/.blitz/shell/init.sh"
        fi
        \(Self.endMarker)
        """
    }

    private func removingManagedBlock(from text: String) -> String {
        var contents = text

        while let startRange = contents.range(of: Self.startMarker),
              let endRange = contents.range(of: Self.endMarker, range: startRange.lowerBound..<contents.endIndex) {
            var lowerBound = startRange.lowerBound
            if lowerBound > contents.startIndex {
                let previousIndex = contents.index(before: lowerBound)
                if contents[previousIndex] == "\n" {
                    lowerBound = previousIndex
                }
            }

            var upperBound = endRange.upperBound
            if upperBound < contents.endIndex, contents[upperBound] == "\n" {
                upperBound = contents.index(after: upperBound)
            }

            contents.removeSubrange(lowerBound..<upperBound)
        }

        while contents.contains("\n\n\n") {
            contents = contents.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        return contents
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func detectShellKind(_ shellPath: String?) -> ShellKind {
        let shellName = URL(fileURLWithPath: shellPath ?? "").lastPathComponent
        switch shellName {
        case "zsh":
            return .zsh
        case "bash":
            return .bash
        default:
            return .unsupported(shellPath)
        }
    }

    private static func defaultLoginShellPath() -> String? {
        guard let entry = getpwuid(getuid()) else { return nil }
        let shellPath = String(cString: entry.pointee.pw_shell)
        return shellPath.isEmpty ? nil : shellPath
    }
}

enum ShellIntegrationError: LocalizedError {
    case unsupportedShell(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedShell(let shellName):
            return "Automatic shell integration only supports zsh and bash. Detected \(shellName)."
        }
    }
}

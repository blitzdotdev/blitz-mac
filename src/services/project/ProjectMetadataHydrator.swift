import Foundation

struct ProjectMetadataHydrator {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func hydrate(_ metadata: BlitzProjectMetadata, projectDirectory: URL) -> (metadata: BlitzProjectMetadata, didChange: Bool) {
        var hydrated = metadata
        var didChange = false

        if isBlank(hydrated.bundleIdentifier),
           let bundleIdentifier = discoverBundleIdentifier(projectDirectory: projectDirectory) {
            hydrated.bundleIdentifier = bundleIdentifier
            didChange = true
        }

        return (hydrated, didChange)
    }

    func discoverBundleIdentifier(projectDirectory: URL) -> String? {
        let root = projectDirectory.resolvingSymlinksInPath()

        if let fromXcodeProject = discoverBundleIdentifierInXcodeProjects(root: root) {
            return fromXcodeProject
        }

        return discoverBundleIdentifierInInfoPlists(root: root)
    }

    private func discoverBundleIdentifierInXcodeProjects(root: URL) -> String? {
        for xcodeprojURL in findFiles(
            named: nil,
            withExtension: "xcodeproj",
            under: root
        ) {
            let pbxprojURL = xcodeprojURL.appendingPathComponent("project.pbxproj")
            guard fileManager.fileExists(atPath: pbxprojURL.path),
                  let content = try? String(contentsOf: pbxprojURL, encoding: .utf8) else {
                continue
            }

            let pattern = #"PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;]+);"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(content.startIndex..., in: content)

            for match in regex.matches(in: content, range: range) {
                guard let candidateRange = Range(match.range(at: 1), in: content),
                      let bundleIdentifier = normalizeBundleIdentifier(String(content[candidateRange])) else {
                    continue
                }
                return bundleIdentifier
            }
        }

        return nil
    }

    private func discoverBundleIdentifierInInfoPlists(root: URL) -> String? {
        for plistURL in findFiles(named: "Info.plist", withExtension: nil, under: root) {
            guard let data = fileManager.contents(atPath: plistURL.path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let rawBundleIdentifier = plist["CFBundleIdentifier"] as? String,
                  let bundleIdentifier = normalizeBundleIdentifier(rawBundleIdentifier) else {
                continue
            }
            return bundleIdentifier
        }

        return nil
    }

    private func findFiles(named expectedName: String?, withExtension expectedExtension: String?, under root: URL) -> [URL] {
        guard fileManager.fileExists(atPath: root.path),
              let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var matches: [URL] = []

        while let entry = enumerator.nextObject() as? URL {
            let name = entry.lastPathComponent

            if Self.skippedDirectories.contains(name) {
                enumerator.skipDescendants()
                continue
            }

            if let expectedName, name == expectedName {
                matches.append(entry)
                continue
            }

            if let expectedExtension, entry.pathExtension == expectedExtension {
                matches.append(entry)
                enumerator.skipDescendants()
            }
        }

        return matches
    }

    private func normalizeBundleIdentifier(_ rawValue: String?) -> String? {
        guard var candidate = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty else {
            return nil
        }

        if candidate.hasPrefix("\""), candidate.hasSuffix("\""), candidate.count >= 2 {
            candidate.removeFirst()
            candidate.removeLast()
        }

        if candidate.contains("$(") || candidate.contains("${") {
            return nil
        }

        guard candidate.contains("."),
              candidate.range(
                of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#,
                options: .regularExpression
              ) != nil else {
            return nil
        }

        return candidate
    }

    private func isBlank(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    private static let skippedDirectories: Set<String> = [
        ".build",
        ".git",
        "DerivedData",
        "Pods",
        "build",
        "node_modules"
    ]
}

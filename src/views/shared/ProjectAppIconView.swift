import AppKit
import SwiftUI

private enum ProjectAppIconLookupState {
    case unresolved
    case resolved(String)
    case missing
}

enum ProjectAppIconLoader {
    private static let imageCache = NSCache<NSString, NSImage>()
    private static let lock = NSLock()
    private static var pathCache: [String: ProjectAppIconLookupState] = [:]
    private static let skippedDirectories: Set<String> = [
        "node_modules",
        "Pods",
        ".git",
        ".build",
        "DerivedData",
        "build"
    ]

    static func cachedImage(for projectId: String) -> NSImage? {
        imageCache.object(forKey: projectId as NSString)
    }

    static func loadImage(for projectId: String) async -> NSImage? {
        if let cached = cachedImage(for: projectId) {
            return cached
        }

        guard let path = await loadPath(for: projectId),
              let image = NSImage(contentsOfFile: path) else {
            return nil
        }

        imageCache.setObject(image, forKey: projectId as NSString)
        return image
    }

    private static func loadPath(for projectId: String) async -> String? {
        switch cachedPath(for: projectId) {
        case .resolved(let path):
            return path
        case .missing:
            return nil
        case .unresolved:
            break
        }

        let path = await Task.detached(priority: .utility) {
            findIconPath(for: projectId)
        }.value

        cachePath(path, for: projectId)
        return path
    }

    private static func cachedPath(for projectId: String) -> ProjectAppIconLookupState {
        lock.lock()
        defer { lock.unlock() }
        return pathCache[projectId] ?? .unresolved
    }

    private static func cachePath(_ path: String?, for projectId: String) {
        lock.lock()
        defer { lock.unlock() }
        pathCache[projectId] = path.map(ProjectAppIconLookupState.resolved) ?? .missing
    }

    private static func findIconPath(for projectId: String) -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let projectDir = URL(fileURLWithPath: "\(home)/.blitz/projects/\(projectId)")

        let generatedIcon = projectDir.appendingPathComponent("assets/AppIcon/icon_1024.png")
        if fm.fileExists(atPath: generatedIcon.path) {
            return generatedIcon.path
        }

        let searchRoots = [
            projectDir.appendingPathComponent("ios"),
            projectDir.appendingPathComponent("macos"),
            projectDir
        ]

        for root in searchRoots where fm.fileExists(atPath: root.path) {
            if let path = findIconPath(in: root, using: fm) {
                return path
            }
        }

        return nil
    }

    private static func findIconPath(in root: URL, using fm: FileManager) -> String? {
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        while let entry = enumerator.nextObject() as? URL {
            let name = entry.lastPathComponent

            if skippedDirectories.contains(name) {
                enumerator.skipDescendants()
                continue
            }

            guard name == "Contents.json",
                  entry.deletingLastPathComponent().lastPathComponent == "AppIcon.appiconset",
                  let data = fm.contents(atPath: entry.path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let images = json["images"] as? [[String: Any]] else {
                continue
            }

            for image in images {
                guard let filename = image["filename"] as? String else { continue }
                let iconPath = entry.deletingLastPathComponent().appendingPathComponent(filename).path
                if fm.fileExists(atPath: iconPath) {
                    return iconPath
                }
            }
        }

        return nil
    }
}

struct ProjectAppIconView<Placeholder: View>: View {
    let project: Project
    let size: CGFloat
    let cornerRadius: CGFloat
    let placeholder: () -> Placeholder

    @State private var icon: NSImage?

    init(
        project: Project,
        size: CGFloat,
        cornerRadius: CGFloat,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.project = project
        self.size = size
        self.cornerRadius = cornerRadius
        self.placeholder = placeholder
        _icon = State(initialValue: ProjectAppIconLoader.cachedImage(for: project.id))
    }

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                placeholder()
            }
        }
        .frame(width: size, height: size)
        .task(id: project.id) {
            await loadIcon()
        }
    }

    @MainActor
    private func loadIcon() async {
        if let cached = ProjectAppIconLoader.cachedImage(for: project.id) {
            icon = cached
            return
        }

        icon = nil
        icon = await ProjectAppIconLoader.loadImage(for: project.id)
    }
}

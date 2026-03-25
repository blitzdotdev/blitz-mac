import SwiftUI

struct ImportProjectSheet: View {
    @Bindable var appState: AppState
    @Binding var isPresented: Bool

    @State private var projectPath = ""
    @State private var platform: ProjectPlatform = .iOS
    @State private var projectType: ProjectType = .reactNative
    @State private var isImporting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Import Project")
                .font(.headline)

            Form {
                HStack {
                    TextField("Project Path", text: $projectPath)
                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            projectPath = url.path
                            if let detected = detectProject(at: url) {
                                platform = detected.platform
                                projectType = detected.type
                            }
                        }
                    }
                }

                Picker("Platform", selection: $platform) {
                    Text("iOS").tag(ProjectPlatform.iOS)
                    Text("macOS").tag(ProjectPlatform.macOS)
                }
                .pickerStyle(.segmented)
                .onChange(of: platform) { _, newPlatform in
                    if newPlatform == .macOS {
                        projectType = .swift
                    }
                }

                if platform == .iOS {
                    Picker("Type", selection: $projectType) {
                        Text("React Native").tag(ProjectType.reactNative)
                        Text("Swift").tag(ProjectType.swift)
                        Text("Flutter").tag(ProjectType.flutter)
                    }
                } else {
                    Picker("Type", selection: $projectType) {
                        Text("Swift").tag(ProjectType.swift)
                    }
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Import") {
                    Task { await importProject() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(projectPath.isEmpty || isImporting)
            }
        }
        .padding()
        .frame(width: 450)
    }

    private struct DetectedProject {
        let type: ProjectType
        let platform: ProjectPlatform
    }

    /// Detect project type and platform from directory contents.
    private func detectProject(at url: URL) -> DetectedProject? {
        let fm = FileManager.default
        // Flutter: pubspec.yaml with "flutter:" dependency
        let pubspec = url.appendingPathComponent("pubspec.yaml")
        if fm.fileExists(atPath: pubspec.path),
           let contents = try? String(contentsOf: pubspec, encoding: .utf8),
           contents.contains("flutter:") {
            return DetectedProject(type: .flutter, platform: .iOS)
        }
        // Swift: .xcodeproj, .xcworkspace, or Package.swift
        let dirContents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        let hasXcodeProj = dirContents.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") })
        let hasPackageSwift = fm.fileExists(atPath: url.appendingPathComponent("Package.swift").path)
        if hasXcodeProj || hasPackageSwift {
            // Detect macOS vs iOS by checking pbxproj for SDKROOT or MACOSX_DEPLOYMENT_TARGET
            let detectedPlatform = detectSwiftPlatform(at: url, dirContents: dirContents)
            return DetectedProject(type: .swift, platform: detectedPlatform)
        }
        // React Native: package.json with react-native dependency
        let packageJson = url.appendingPathComponent("package.json")
        if fm.fileExists(atPath: packageJson.path),
           let contents = try? String(contentsOf: packageJson, encoding: .utf8),
           contents.contains("\"react-native\"") {
            return DetectedProject(type: .reactNative, platform: .iOS)
        }
        return nil
    }

    /// Check xcodeproj for macOS vs iOS indicators
    private func detectSwiftPlatform(at url: URL, dirContents: [String]) -> ProjectPlatform {
        guard let xcodeproj = dirContents.first(where: { $0.hasSuffix(".xcodeproj") }) else {
            return .iOS
        }
        let pbxprojPath = url.appendingPathComponent(xcodeproj).appendingPathComponent("project.pbxproj").path
        guard let contents = try? String(contentsOfFile: pbxprojPath, encoding: .utf8) else {
            return .iOS
        }
        if contents.contains("SDKROOT = macosx") || contents.contains("MACOSX_DEPLOYMENT_TARGET") {
            return .macOS
        }
        return .iOS
    }

    private func importProject() async {
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }

        let url = URL(fileURLWithPath: projectPath)

        // Validate selected type matches detected type
        if let detected = detectProject(at: url) {
            if detected.type != projectType {
                let detectedName: String
                switch detected.type {
                case .reactNative: detectedName = "React Native"
                case .swift: detectedName = "Swift"
                case .flutter: detectedName = "Flutter"
                }
                errorMessage = "This looks like a \(detectedName) project. Please select the correct type."
                return
            }
        }

        let storage = ProjectStorage()
        let metadata = BlitzProjectMetadata(
            name: url.lastPathComponent,
            type: projectType,
            platform: platform,
            createdAt: Date(),
            lastOpenedAt: Date()
        )

        do {
            // Write metadata into the original project directory first,
            // then register it as a symlink in ~/.blitz/projects/.
            // This ensures all Blitz files land in the actual project, not a detached directory.
            try storage.writeMetadataToDirectory(url, metadata: metadata)
            let projectId = try storage.openProject(at: url)
            storage.ensureMCPConfig(
                projectId: projectId,
                whitelistBlitzMCP: appState.settingsStore.whitelistBlitzMCPTools,
                allowASCCLICalls: appState.settingsStore.allowASCCLICalls
            )
            storage.ensureTeenybaseBackend(projectId: projectId, projectType: projectType)
            storage.ensureClaudeFiles(
                projectId: projectId,
                projectType: projectType,
                whitelistBlitzMCP: appState.settingsStore.whitelistBlitzMCPTools,
                allowASCCLICalls: appState.settingsStore.allowASCCLICalls
            )
            await appState.projectManager.loadProjects()
            appState.activeProjectId = projectId
            isPresented = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

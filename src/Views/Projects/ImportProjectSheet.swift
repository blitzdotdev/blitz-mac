import SwiftUI

struct ImportProjectSheet: View {
    @Bindable var appState: AppState
    @Binding var isPresented: Bool

    @State private var projectPath = ""
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
                        }
                    }
                }

                Picker("Type", selection: $projectType) {
                    Text("React Native").tag(ProjectType.reactNative)
                    Text("Swift").tag(ProjectType.swift)
                    Text("Flutter").tag(ProjectType.flutter)
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

    private func importProject() async {
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }

        // TODO: Call sidecar to import project
        // For now, just create metadata
        let url = URL(fileURLWithPath: projectPath)
        let name = url.lastPathComponent

        let storage = ProjectStorage()
        let metadata = BlitzProjectMetadata(
            name: name,
            type: projectType,
            createdAt: Date(),
            lastOpenedAt: Date()
        )

        do {
            try storage.writeMetadata(projectId: name, metadata: metadata)
            storage.ensureMCPConfig(projectId: name)
            await appState.projectManager.loadProjects()
            appState.activeProjectId = name
            isPresented = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

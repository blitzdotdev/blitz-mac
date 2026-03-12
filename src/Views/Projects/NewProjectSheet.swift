import SwiftUI

struct NewProjectSheet: View {
    @Bindable var appState: AppState
    @Binding var isPresented: Bool

    @State private var projectName = ""
    @State private var projectType: ProjectType = .blitz
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("New Project")
                .font(.headline)

            Form {
                TextField("Project Name", text: $projectName)

                Picker("Type", selection: $projectType) {
                    Text("Blitz").tag(ProjectType.blitz)
                    Text("React Native").tag(ProjectType.reactNative)
                    Text("Swift").tag(ProjectType.swift)
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

                Button("Create") {
                    Task { await createProject() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(projectName.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }

    private func createProject() async {
        errorMessage = nil

        let storage = ProjectStorage()
        let metadata = BlitzProjectMetadata(
            name: projectName,
            type: projectType,
            createdAt: Date(),
            lastOpenedAt: Date()
        )

        let projectId = projectName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }

        // Write metadata first
        do {
            try storage.writeMetadata(projectId: projectId, metadata: metadata)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        // Reload project list so the new project appears in the switcher
        await appState.projectManager.loadProjects()

        // Flag that this project needs setup — ContentView will trigger it
        appState.projectSetup.pendingSetupProjectId = projectId

        // Select the new project and dismiss immediately
        appState.activeProjectId = projectId
        isPresented = false
    }
}

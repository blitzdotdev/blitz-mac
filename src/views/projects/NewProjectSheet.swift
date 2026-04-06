import SwiftUI

struct NewProjectSheet: View {
    @Bindable var appState: AppState
    @Binding var isPresented: Bool

    @State private var projectName = ""
    @State private var platform: ProjectPlatform = .iOS
    @State private var projectType: ProjectType = .swift
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("New Project")
                .font(.headline)

            Form {
                TextField("Project Name", text: $projectName)

                Picker("Platform", selection: $platform) {
                    Text("iOS").tag(ProjectPlatform.iOS)
                    Text("macOS").tag(ProjectPlatform.macOS)
                }
                .pickerStyle(.segmented)
                .onChange(of: platform) { _, newPlatform in
                    // macOS only supports Swift for now
                    if newPlatform == .macOS {
                        projectType = .swift
                    }
                }

                if platform == .iOS {
                    Picker("Type", selection: $projectType) {
                        Text("React Native").tag(ProjectType.reactNative)
                        Text("Swift").tag(ProjectType.swift)
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
            platform: platform,
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

        AnalyticsService.trackProjectCreate(projectType: projectType)

        // Reload project list so the new project appears in the switcher
        await appState.projectManager.loadProjects()

        // Flag that this project needs setup — ContentView will trigger it
        appState.projectSetup.pendingSetupProjectId = projectId

        // Clear the sheet flag before switching projects — showNewProjectSheet is on
        // shared appState, so if it stays true the main window's .sheet binding fires too.
        appState.showNewProjectSheet = false

        // Open on App > Overview tab, then select the new project —
        // WelcomeWindow's onChange will open main window and close the welcome window.
        appState.activeTab = .app
        appState.activeAppSubTab = .overview
        appState.activeProjectId = projectId
    }
}

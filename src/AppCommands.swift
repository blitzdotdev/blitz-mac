import SwiftUI

struct AppCommands: Commands {
    let appState: AppState

    var body: some Commands {
        // Replace File menu contents with Project items
        CommandGroup(replacing: .newItem) {
            Button("New Project...") {
                appState.showNewProjectSheet = true
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Open Project...") {
                openProjectFromMenu()
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("Import Project...") {
                appState.showImportProjectSheet = true
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])

            Divider()

            // Open Recent submenu
            Menu("Open Recent") {
                let sorted = appState.projectManager.projects.sorted {
                    ($0.metadata.lastOpenedAt ?? .distantPast) > ($1.metadata.lastOpenedAt ?? .distantPast)
                }

                if sorted.isEmpty {
                    Text("No Recent Projects")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sorted) { project in
                        Button {
                            let storage = ProjectStorage()
                            storage.updateLastOpened(projectId: project.id)
                            appState.activeProjectId = project.id
                        } label: {
                            Label(project.name, systemImage: projectIcon(project))
                        }
                    }

                    Divider()

                    Button("Clear Recent Projects") {
                        let storage = ProjectStorage()
                        storage.clearRecentProjects()
                        Task {
                            await appState.projectManager.loadProjects()
                        }
                    }
                }
            }

            Divider()

            Button("Close Project") {
                appState.activeProjectId = nil
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(appState.activeProjectId == nil)
        }

        // View menu additions
        CommandGroup(after: .toolbar) {
            Divider()

            Button("Dashboard") {
                appState.activeTab = .dashboard
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("Simulator") {
                appState.activeTab = .app
                appState.activeAppSubTab = .simulator
            }
            .keyboardShortcut("2", modifiers: .command)

            Button("Database") {
                appState.activeTab = .app
                appState.activeAppSubTab = .database
            }
            .keyboardShortcut("3", modifiers: .command)
        }

        // View > Terminal toggle
        CommandGroup(after: .sidebar) {
            Button(appState.showTerminal ? "Hide Terminal" : "Show Terminal") {
                appState.showTerminal.toggle()
                if appState.showTerminal && appState.terminalManager.sessions.isEmpty {
                    appState.terminalManager.createSession(projectPath: appState.activeProject?.path)
                }
            }
            .keyboardShortcut("`", modifiers: .command)
        }

        // Build menu
        CommandMenu("Build") {
            Button("Run") {
                guard let project = appState.activeProject else { return }
                Task {
                    await appState.simulatorManager.bootIfNeeded()
                    await appState.simulatorStream.startStreaming(
                        bootedDeviceId: appState.simulatorManager.bootedDeviceId
                    )
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(appState.activeProjectId == nil)

            Button("Stop") {
                Task { await appState.simulatorStream.stopStreaming() }
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!appState.simulatorStream.isCapturing)
        }
    }

    private func openProjectFromMenu() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a Blitz project folder"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let storage = ProjectStorage()
        do {
            let projectId = try storage.openProject(at: url)
            Task {
                await appState.projectManager.loadProjects()
                appState.activeProjectId = projectId
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Cannot Open Project"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func projectIcon(_ project: Project) -> String {
        if project.platform == .macOS { return "desktopcomputer" }
        switch project.type {
        case .reactNative: return "atom"
        case .swift: return "swift"
        case .flutter: return "bird"
        }
    }
}

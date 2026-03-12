import SwiftUI

struct WelcomeWindow: View {
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var welcomeWindow: NSWindow?

    var body: some View {
        HStack(spacing: 0) {
            leftPanel
            rightPanel
        }
        .background(.ultraThickMaterial)
        .background(WindowFinder { window in
            welcomeWindow = window
        })
        .task {
            if appState.projectManager.projects.isEmpty {
                await appState.projectManager.loadProjects()
            }
        }
        .onChange(of: appState.activeProjectId) { _, newValue in
            if let projectId = newValue {
                // Open main project window, close welcome
                openWindow(id: "main", value: projectId)
                welcomeWindow?.close()
            }
        }
        .sheet(isPresented: $appState.showNewProjectSheet) {
            NewProjectSheet(appState: appState, isPresented: $appState.showNewProjectSheet)
        }
        .sheet(isPresented: $appState.showImportProjectSheet) {
            ImportProjectSheet(appState: appState, isPresented: $appState.showImportProjectSheet)
        }
    }

    // MARK: - Left Panel

    private var leftPanel: some View {
        VStack(spacing: 20) {
            Spacer()

            Group {
                if let icon = Bundle.module.image(forResource: "blitz-icon") {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 96, height: 96)
                } else if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 96, height: 96)
                }
            }

            VStack(spacing: 4) {
                Text("Blitz")
                    .font(.system(size: 28, weight: .bold))

                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(spacing: 8) {
                welcomeButton(
                    title: "Create a New Project...",
                    icon: "plus.square",
                    action: { appState.showNewProjectSheet = true }
                )

                welcomeButton(
                    title: "Open a Project...",
                    icon: "folder",
                    action: openProject
                )

                welcomeButton(
                    title: "Import a Project...",
                    icon: "square.and.arrow.down",
                    action: { appState.showImportProjectSheet = true }
                )
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .frame(width: 700 * 0.45)
        .background(
            LinearGradient(
                colors: [Color(white: 0.1), Color(white: 0.15)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - Right Panel

    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent Projects")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Divider()

            if recentProjects.isEmpty {
                Spacer()
                Text("No Recent Projects")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(recentProjects) { project in
                        Button {
                            selectProject(project)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: projectIcon(project.type))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.name)
                                        .font(.body)
                                        .lineLimit(1)

                                    Text(project.path)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private var recentProjects: [Project] {
        appState.projectManager.projects.sorted {
            ($0.metadata.lastOpenedAt ?? .distantPast) > ($1.metadata.lastOpenedAt ?? .distantPast)
        }
    }

    private func welcomeButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 20)
                Text(title)
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func selectProject(_ project: Project) {
        let storage = ProjectStorage()
        storage.updateLastOpened(projectId: project.id)
        appState.activeProjectId = project.id
    }

    private func openProject() {
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

    private func projectIcon(_ type: ProjectType) -> String {
        switch type {
        case .blitz: return "bolt.fill"
        case .reactNative: return "atom"
        case .swift: return "swift"
        case .flutter: return "bird"
        }
    }
}

/// Gets a reference to the hosting NSWindow
private struct WindowFinder: NSViewRepresentable {
    var callback: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { self.callback(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { self.callback(nsView.window) }
    }
}

import SwiftUI

struct SidebarView: View {
    @Bindable var appState: AppState

    var body: some View {
        List(selection: $appState.activeTab) {
            // Top-level standalone tabs
            Section {
                Label("Dashboard", systemImage: "square.grid.2x2")
                    .tag(AppTab.dashboard)

                // App tab — shows dynamic project icon + name
                HStack(spacing: 8) {
                    if let project = appState.activeProject {
                        ProjectAppIconView(project: project, size: 18, cornerRadius: 4) {
                            Image(systemName: projectIcon(project))
                                .foregroundStyle(projectColor(project))
                                .frame(width: 18, height: 18)
                        }
                    } else {
                        Image(systemName: "app")
                            .frame(width: 18, height: 18)
                    }
                    Text(appState.activeProject?.name ?? "App")
                        .lineLimit(1)
                }
                .tag(AppTab.app)
            }

            // Release group
            Section("Release") {
                ForEach(AppTab.Group.release.tabs) { tab in
                    Label(tab.label, systemImage: tab.icon)
                        .tag(tab)
                }
            }

            // Insights group
            Section("Insights") {
                ForEach(AppTab.Group.insights.tabs) { tab in
                    Label(tab.label, systemImage: tab.icon)
                        .tag(tab)
                }
            }

            // TestFlight group
            Section("TestFlight") {
                ForEach(AppTab.Group.testFlight.tabs) { tab in
                    Label(tab.label, systemImage: tab.icon)
                        .tag(tab)
                }
            }

            // Settings
            Section {
                Label("Settings", systemImage: "gear")
                    .tag(AppTab.settings)
            }
        }
        .listStyle(.sidebar)
        .scrollDisabled(true)
    }

    private func projectIcon(_ project: Project) -> String {
        if project.platform == .macOS { return "desktopcomputer" }
        switch project.type {
        case .reactNative: return "atom"
        case .swift: return "swift"
        case .flutter: return "bird"
        }
    }

    private func projectColor(_ project: Project) -> Color {
        switch project.type {
        case .reactNative: return .cyan
        case .swift: return .orange
        case .flutter: return .blue
        }
    }
}

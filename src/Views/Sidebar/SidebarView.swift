import SwiftUI

struct SidebarView: View {
    @Bindable var appState: AppState

    private func projectIcon(_ type: ProjectType) -> String {
        switch type {
        case .blitz: return "bolt.fill"
        case .reactNative: return "atom"
        case .swift: return "swift"
        case .flutter: return "bird"
        }
    }

    var body: some View {
        List(selection: $appState.activeTab) {
            // Active project header
            if let project = appState.activeProject {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: projectIcon(project.type))
                            .foregroundStyle(.blue)
                            .font(.system(size: 14))
                        Text(project.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                }
            }

            // Build group
            Section("Build") {
                ForEach(AppTab.Group.build.tabs) { tab in
                    Label(tab.label, systemImage: tab.icon)
                        .tag(tab)
                }
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
    }
}

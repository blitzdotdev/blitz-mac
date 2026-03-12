import SwiftUI

struct ProjectListView: View {
    @Bindable var appState: AppState

    var body: some View {
        ForEach(appState.projectManager.projects) { project in
            HStack {
                Image(systemName: projectIcon(project.type))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.system(size: 12, weight: .medium))
                    Text(project.type.rawValue)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if project.id == appState.activeProjectId {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                appState.activeProjectId = project.id
            }
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

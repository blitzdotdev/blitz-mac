import SwiftUI

/// The App Shots tab. Two top-level views:
///   - `AppShotsHeroView` on first arrival (no captures, no generated sets)
///   - `AppShotsWorkspaceView` for everything else — a 3-column persistent canvas
///     where capture / generation / done states are all rendered in the same layout.
struct AppShotsView: View {
    var appState: AppState

    @State private var manager = AppShotsFlowManager()

    private var projectId: String? { appState.activeProjectId }
    private var projectName: String { appState.activeProject?.name ?? "Your App" }
    private var bootedUDID: String? { appState.simulatorManager.bootedDeviceId }

    var body: some View {
        ZStack {
            AppShotsBackground()
            content
        }
        .task {
            await manager.bootstrap(projectId: projectId, projectName: projectName)
        }
        .onChange(of: projectId) { _, _ in
            Task { await manager.bootstrap(projectId: projectId, projectName: projectName) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch manager.step {
        case .hero:
            AppShotsHeroView(hasProject: projectId != nil) {
                manager.startBuilding()
            }
        case .capture, .generating, .done:
            AppShotsWorkspaceView(manager: manager, bootedUDID: bootedUDID, projectName: projectName)
        }
    }
}
import SwiftUI

struct DashboardView: View {
    @Bindable var appState: AppState
    @State private var dashboardSummary = DashboardSummaryStore.shared

    private var projects: [Project] { appState.projectManager.projects }
    private var summaryHydrationKey: String {
        let credentialsKey = appState.ascManager.credentials?.keyId ?? "no-creds"
        let fingerprint = projects
            .map { "\($0.id):\($0.metadata.bundleIdentifier ?? "")" }
            .sorted()
            .joined(separator: "|")
        return "\(credentialsKey):\(appState.ascManager.credentialActivationRevision):\(fingerprint)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Sub-tab navbar
            topNavbar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)

            Divider()

            // Sub-tab content
            subTabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Top Navbar

    private var topNavbar: some View {
        HStack(spacing: 2) {
            ForEach(DashboardSubTab.allCases) { tab in
                Button {
                    appState.activeDashboardSubTab = tab
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 11))
                        Text(tab.label)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        appState.activeDashboardSubTab == tab
                            ? Color.accentColor.opacity(0.12)
                            : Color.clear
                    )
                    .foregroundStyle(
                        appState.activeDashboardSubTab == tab
                            ? Color.accentColor
                            : Color.secondary
                    )
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
    }

    // MARK: - Sub-tab Content

    @ViewBuilder
    private var subTabContent: some View {
        switch appState.activeDashboardSubTab {
        case .myApps:
            myAppsContent
        case .allApps:
            AllAppsView(appState: appState)
        }
    }

    private var myAppsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Stat cards
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 12
                ) {
                    statCard(
                        title: "Live on Store",
                        value: statValue(dashboardSummary.summary.liveCount),
                        color: .green,
                        icon: "checkmark.seal.fill"
                    )
                    statCard(
                        title: "Pending Review",
                        value: statValue(dashboardSummary.summary.pendingCount),
                        color: .orange,
                        icon: "clock.fill"
                    )
                    statCard(
                        title: "Rejected Apps",
                        value: statValue(dashboardSummary.summary.rejectedCount),
                        color: .red,
                        icon: "xmark.seal.fill"
                    )
                }

                // App grid
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 8, alignment: .leading)],
                    spacing: 16
                ) {
                    ForEach(projects) { project in
                        appCard(project: project)
                            .onTapGesture {
                                selectProject(project)
                            }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DottedCanvasBackground())
        .overlay(alignment: .bottomTrailing) {
            Button {
                appState.showNewProjectSheet = true
            } label: {
                Label("Create App", systemImage: "plus")
                    .font(.body.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(20)
        }
        .overlay(alignment: .topTrailing) {
            if dashboardSummary.isLoadingSummary {
                ProgressView()
                    .controlSize(.small)
                    .padding(12)
                    .background(.background.secondary, in: Capsule())
                    .padding(20)
            }
        }
        .task(id: summaryHydrationKey) {
            await hydrateSummary()
        }
    }

    // MARK: - Stat Card

    private func statCard(title: String, value: String, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.callout)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - App Card

    private func appCard(project: Project) -> some View {
        let isSelected = project.id == appState.activeProjectId

        return VStack(spacing: 6) {
            ProjectAppIconView(project: project, size: 56, cornerRadius: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(projectColor(project).opacity(0.15))
                    Image(systemName: projectIcon(project))
                        .font(.system(size: 24))
                        .foregroundStyle(projectColor(project))
                }
            }
            .padding(3)
            .overlay(
                RoundedRectangle(cornerRadius: 15)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )

            HStack(spacing: 3) {
                statusIcon(for: project)
                    .font(.system(size: 9))
                Text(project.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    private func selectProject(_ project: Project) {
        appState.activeProjectId = project.id
        let projectId = project.id
        Task.detached(priority: .utility) {
            ProjectStorage().updateLastOpened(projectId: projectId)
        }
    }

    private func hydrateSummary() async {
        if projects.isEmpty {
            await appState.projectManager.loadProjects()
        }

        let hydrationKey = summaryHydrationKey
        if dashboardSummary.isLoading(for: hydrationKey) || !dashboardSummary.shouldRefresh(for: hydrationKey) {
            return
        }

        let eligibleProjects = appState.projectManager.projects.compactMap { project -> DashboardProjectInput? in
            guard let bundleId = project.metadata.bundleIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !bundleId.isEmpty else {
                return nil
            }
            return DashboardProjectInput(bundleId: bundleId)
        }

        guard !eligibleProjects.isEmpty else {
            dashboardSummary.markEmpty(for: hydrationKey)
            return
        }

        guard let credentials = ASCCredentials.load() else {
            dashboardSummary.markUnavailable(for: hydrationKey)
            return
        }

        dashboardSummary.beginLoading(for: hydrationKey)
        var nextSummary = ASCDashboardSummary.empty
        var nextStatuses: [String: ASCDashboardProjectStatus] = [:]
        let service = AppStoreConnectService(credentials: credentials)

        for project in eligibleProjects {
            if Task.isCancelled {
                dashboardSummary.cancelLoading(for: hydrationKey)
                return
            }

            do {
                let app = try await service.fetchApp(bundleId: project.bundleId)
                let versions = try await service.fetchAppStoreVersions(appId: app.id)
                let status = ASCDashboardProjectStatus(versions: versions)
                nextSummary.include(status)
                nextStatuses[project.bundleId] = status
            } catch {
                continue
            }
        }

        if Task.isCancelled {
            dashboardSummary.cancelLoading(for: hydrationKey)
            return
        }

        dashboardSummary.store(summary: nextSummary, projectStatuses: nextStatuses, for: hydrationKey)
    }

    // MARK: - Helpers

    private func statValue(_ count: Int) -> String {
        dashboardSummary.hasLoadedSummary ? "\(count)" : (projects.isEmpty ? "0" : "-")
    }

    @ViewBuilder
    private func statusIcon(for project: Project) -> some View {
        let bundleId = project.metadata.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let status = dashboardSummary.projectStatuses[bundleId] {
            if status.isRejected {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            } else if status.isPendingReview {
                Image(systemName: "clock.fill")
                    .foregroundStyle(.orange)
            } else if status.isLiveOnStore {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "pencil.circle.fill")
                    .foregroundStyle(.secondary)
            }
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

    private func projectColor(_ project: Project) -> Color {
        switch project.type {
        case .reactNative: return .cyan
        case .swift: return .orange
        case .flutter: return .blue
        }
    }

    private struct DashboardProjectInput: Sendable {
        let bundleId: String
    }
}

import SwiftUI

struct DashboardView: View {
    @Bindable var appState: AppState
    @State private var dashboardSummary = DashboardSummaryStore.shared
    @State private var appWallRefreshRevision = 0
    @State private var isRefreshingAllApps = false

    private var projects: [Project] { appState.projectManager.projects }

    private var dashboardAccountKey: String? {
        DashboardSummaryStore.accountKey(
            for: appState.ascManager.credentials ?? ASCCredentials.load()
        )
    }

    /// Only the ASC account identity and explicit credential activation should
    /// restart the network hydration task. Local project changes are linked in
    /// memory and should not cancel an in-flight ASC fetch.
    private var summaryHydrationKey: String {
        DashboardSummaryStore.cacheKey(
            accountKey: dashboardAccountKey,
            credentialActivationRevision: appState.ascManager.credentialActivationRevision
        )
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

            Button {
                forceRefreshCurrentSubTab()
            } label: {
                if isRefreshingCurrentSubTab {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(.borderless)
            .disabled(isRefreshingCurrentSubTab)
            .help(refreshButtonHelpText)
        }
    }

    // MARK: - Sub-tab Content

    @ViewBuilder
    private var subTabContent: some View {
        switch appState.activeDashboardSubTab {
        case .myApps:
            myAppsContent
        case .allApps:
            AllAppsView(
                appState: appState,
                refreshRevision: appWallRefreshRevision,
                onRefreshStateChange: { isRefreshing in
                    isRefreshingAllApps = isRefreshing
                }
            )
        }
    }

    private var appRows: [DashboardAppRow] { dashboardSummary.rows(linking: projects) }
    private var showsBlockingSummarySpinner: Bool {
        dashboardSummary.isLoadingSummary && !dashboardSummary.hasLoadedSummary
    }
    private var summaryLoadingStatusText: String {
        dashboardSummary.loadingSummaryStatusText ?? "Loading apps…"
    }
    private var isRefreshingCurrentSubTab: Bool {
        switch appState.activeDashboardSubTab {
        case .myApps:
            return dashboardSummary.isLoading(for: summaryHydrationKey)
        case .allApps:
            return isRefreshingAllApps
        }
    }
    private var refreshButtonHelpText: String {
        switch appState.activeDashboardSubTab {
        case .myApps:
            return "Force refresh My Apps"
        case .allApps:
            return "Refresh All Apps"
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

                if !appRows.isEmpty {
                    // App grid — ASC apps first, local-only projects beneath
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 8, alignment: .leading)],
                        spacing: 16
                    ) {
                        ForEach(appRows) { row in
                            appCard(row: row)
                                .onTapGesture { selectRow(row) }
                        }
                    }
                } else if dashboardSummary.hasLoadedSummary {
                    emptyStateView
                }

                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DottedCanvasBackground())
        .overlay {
            if showsBlockingSummarySpinner {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text(summaryLoadingStatusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(spacing: 8) {
                Button {
                    appState.showNewProjectSheet = true
                } label: {
                    Label("Create App", systemImage: "plus")
                        .font(.body.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    appState.showImportProjectSheet = true
                } label: {
                    Label("Import App", systemImage: "square.and.arrow.down")
                        .font(.body.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(20)
        }
        .task(id: summaryHydrationKey) {
            await hydrateSummary()
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No apps yet")
                .font(.headline)
            Text("Create a new app or import an existing project to get started.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
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

    @ViewBuilder
    private func appCard(row: DashboardAppRow) -> some View {
        let isSelected = row.linkedProjectId != nil && row.linkedProjectId == appState.activeProjectId
        let project = row.linkedProjectId.flatMap { id in projects.first(where: { $0.id == id }) }

        VStack(spacing: 6) {
            Group {
                if let project {
                    ProjectAppIconView(project: project, size: 56, cornerRadius: 12) {
                        ascIcon(for: row)
                    }
                } else {
                    ascIcon(for: row)
                }
            }
            .padding(3)
            .overlay(
                RoundedRectangle(cornerRadius: 15)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )

            HStack(spacing: 3) {
                statusIcon(for: row)
                    .font(.system(size: 9))
                Text(row.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }

            if row.source == .localOnly {
                Text("Local only")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func ascIcon(for row: DashboardAppRow) -> some View {
        if let iconURL = row.iconURL {
            AsyncImage(url: iconURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                case .empty:
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.accentColor.opacity(0.08))
                            .frame(width: 56, height: 56)
                        ProgressView()
                            .controlSize(.small)
                    }
                case .failure:
                    fallbackIcon(name: row.name)
                @unknown default:
                    fallbackIcon(name: row.name)
                }
            }
            .frame(width: 56, height: 56)
        } else {
            fallbackIcon(name: row.name)
        }
    }

    private func fallbackIcon(name: String) -> some View {
        let first = String(name.prefix(1)).uppercased()
        return ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: 56, height: 56)
            Text(first.isEmpty ? "?" : first)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.7))
        }
    }

    // MARK: - Actions

    private func selectRow(_ row: DashboardAppRow) {
        // Claim analytics event — one-shot per app key per device.
        let claimKey = row.bundleId ?? row.id

        if let projectId = row.linkedProjectId {
            // Linked local project — open it as before.
            appState.activeTab = .app
            appState.activeAppSubTab = .overview
            appState.activeProjectId = projectId
            let id = projectId
            Task.detached(priority: .utility) {
                ProjectStorage().updateLastOpened(projectId: id)
            }
        } else if let bundleId = row.bundleId {
            // ASC-only app — stay in this window, focus the ASC manager on this bundle id,
            // and route the user to the App > Overview tab so the synthesized dashboard renders.
            appState.activeProjectId = nil
            appState.activeTab = .app
            appState.activeAppSubTab = .overview
            Task {
                await appState.ascManager.loadCredentials(for: "asc:\(bundleId)", bundleId: bundleId)
                await appState.ascManager.ensureTabData(.app)
            }
        }
    }

    private func hydrateSummary(force: Bool = false) async {
        let hydrationKey = summaryHydrationKey
        // Make sure credentials are loaded up front — even if there is no active project,
        // the dashboard should show the user's ASC apps as soon as possible.
        appState.ascManager.loadStoredCredentialsIfNeeded()
        let accountKey = DashboardSummaryStore.accountKey(for: appState.ascManager.credentials)
        guard let service = appState.ascManager.service else {
            dashboardSummary.markUnavailable(for: hydrationKey, accountKey: accountKey)
            return
        }

        await dashboardSummary.refresh(
            for: hydrationKey,
            accountKey: accountKey,
            service: service,
            projects: appState.projectManager.projects,
            force: force
        )
    }

    private func forceRefreshCurrentSubTab() {
        switch appState.activeDashboardSubTab {
        case .myApps:
            Task {
                await hydrateSummary(force: true)
            }
        case .allApps:
            appWallRefreshRevision += 1
        }
    }

    // MARK: - Helpers

    private func statValue(_ count: Int) -> String {
        dashboardSummary.hasLoadedSummary ? "\(count)" : (appRows.isEmpty ? "0" : "-")
    }

    @ViewBuilder
    private func statusIcon(for row: DashboardAppRow) -> some View {
        if let status = row.status {
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
}

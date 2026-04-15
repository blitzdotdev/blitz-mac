import SwiftUI

struct AllAppsView: View {
    @Bindable var appState: AppState
    var refreshRevision: Int = 0
    var onRefreshStateChange: (Bool) -> Void = { _ in }
    @AppStorage("appWallSyncConsented") private var syncConsented: Bool = false
    @AppStorage("appWallSyncPromptShown") private var syncPromptShown: Bool = false

    @State private var apps: [AppWallApp] = []
    @State private var totalCount = 0
    @State private var isLoading = false
    @State private var isLoadingNextPage = false
    @State private var loadError: String?
    @State private var showSyncSheet = false
    @State private var syncSheetForceStart = false
    @State private var selectedApp: AppWallApp?
    @State private var dashboardSummary = DashboardSummaryStore.shared

    @State private var summary: AppWallSummary?
    @State private var isSummaryLoading = false

    // Reads from UserDefaults so retries/partial syncs are reflected without
    // needing a network round-trip or a full view reset.
    private var syncedBundleIds: Set<String> {
        AppWallSyncedBundleIds.load()
    }

    private var unsyncedLiveCount: Int {
        guard syncConsented, dashboardSummary.hasLoadedSummary else { return 0 }
        return appState.projectManager.projects.filter { project in
            guard let bundleId = project.metadata.bundleIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !bundleId.isEmpty else { return false }
            return dashboardSummary.projectStatuses[bundleId]?.isLiveOnStore == true
                && !syncedBundleIds.contains(bundleId)
        }.count
    }

    private var hasMorePages: Bool {
        totalCount > apps.count
    }

    private var isRefreshingForNavbar: Bool {
        isLoading || isLoadingNextPage || isSummaryLoading
    }

    var body: some View {
        Group {
            if isLoading && apps.isEmpty {
                loadingView
            } else if let error = loadError, apps.isEmpty {
                errorView(message: error)
            } else if apps.isEmpty {
                emptyView
            } else {
                appsGrid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DottedCanvasBackground())
        .overlay(alignment: .bottomTrailing) {
            if unsyncedLiveCount > 0 {
                unsyncedBanner
            }
        }
        .task(id: syncConsented) {
            await handleConsentState()
        }
        .onAppear {
            notifyRefreshStateChanged()
        }
        .onDisappear {
            onRefreshStateChange(false)
        }
        .onChange(of: isLoading) { _, _ in
            notifyRefreshStateChanged()
        }
        .onChange(of: isLoadingNextPage) { _, _ in
            notifyRefreshStateChanged()
        }
        .onChange(of: isSummaryLoading) { _, _ in
            notifyRefreshStateChanged()
        }
        .onChange(of: refreshRevision) { oldValue, newValue in
            guard newValue != oldValue else { return }
            Task {
                await refreshFromNavbar()
            }
        }
        .sheet(isPresented: $showSyncSheet, onDismiss: handleSyncSheetDismissed) {
            AppWallSyncSheet(
                appState: appState,
                forceStart: syncSheetForceStart,
                onSyncCompleted: {
                    Task { await loadApps() }
                }
            )
        }
        .sheet(item: $selectedApp) { app in
            AppWallDetailView(app: app)
        }
    }

    private func handleConsentState() async {
        await loadApps()
        await loadSummary()
        if !syncConsented && !syncPromptShown { presentSyncSheet() }
    }

    private func presentSyncSheet(forceStart: Bool = false) {
        syncPromptShown = true
        syncSheetForceStart = forceStart
        showSyncSheet = true
    }

    private func handleSyncSheetDismissed() {
        syncSheetForceStart = false
        Task {
            await loadApps()
            await loadSummary()
        }
    }

    private func notifyRefreshStateChanged() {
        onRefreshStateChange(isRefreshingForNavbar)
    }

    private func refreshFromNavbar() async {
        await loadApps(reset: true)
        await loadSummary()
    }

    // MARK: - Sub-views

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading App Wall…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 14) {
            forceSyncActionRow
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Failed to load apps")
                .font(.callout.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await loadApps() }
            }
        }
        .padding(40)
    }

    private var emptyView: some View {
        VStack(spacing: 14) {
            forceSyncActionRow
            Image(systemName: "globe")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No apps on the wall yet")
                .font(.callout.weight(.medium))
            Text("Be the first to sync your apps.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var appsGrid: some View {
        ScrollView {
            VStack(spacing: 16) {
                forceSyncActionRow
                summaryCards
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 8)],
                    spacing: 16
                ) {
                    ForEach(apps) { app in
                        appCard(app: app)
                            .onTapGesture { selectedApp = app }
                            .contentShape(Rectangle())
                    }
                }
                if hasMorePages {
                    loadMoreSection
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private var forceSyncActionRow: some View {
        // NOTE: uncomment for debugging purposes
        if false {
            HStack {
                Spacer()
                Button("Force Sync") {
                    presentSyncSheet(forceStart: true)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var loadMoreSection: some View {
        VStack(spacing: 8) {
            Text("Showing \(apps.count) of \(totalCount) apps")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task { await loadApps(reset: false) }
            } label: {
                if isLoadingNextPage {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 120)
                } else {
                    Text("Load More")
                        .frame(minWidth: 120)
                }
            }
            .buttonStyle(.bordered)
            .disabled(isLoadingNextPage || isLoading)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: - Summary Cards

    private var summaryCards: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
            ],
            spacing: 12
        ) {
            summaryCard(
                title: "Total Apps",
                value: summaryValue { "\($0.totalApps)" },
                color: .blue,
                icon: "square.grid.2x2.fill"
            )
            summaryCard(
                title: "Avg Review Time",
                value: summaryValue { formatReviewHours($0.avgReviewHours) },
                color: .orange,
                icon: "clock.fill"
            )
            summaryCard(
                title: "1st Rejection %",
                value: summaryValue { formatPercent($0.firstSubmitRejectionRate) },
                color: .red,
                icon: "xmark.seal.fill"
            )
            summaryCard(
                title: "Avg Rejects until success",
                value: summaryValue { formatDecimal($0.avgRejectionsUntilFirstLive) },
                color: .purple,
                icon: "arrow.counterclockwise"
            )
        }
    }

    private func summaryCard(title: String, value: String, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.callout)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if isSummaryLoading && summary == nil {
                ProgressView()
                    .controlSize(.small)
                    .frame(height: 28)
            } else {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func summaryValue(_ transform: (AppWallSummary) -> String) -> String {
        guard let summary else { return "--" }
        return transform(summary)
    }

    private func formatReviewHours(_ hours: Double?) -> String {
        guard let hours else { return "--" }
        if hours < 1 {
            return String(format: "%.0fm", hours * 60)
        }
        return String(format: "%.1fh", hours)
    }

    private func formatPercent(_ ratio: Double?) -> String {
        guard let ratio else { return "--" }
        return String(format: "%.0f%%", ratio * 100)
    }

    private func formatDecimal(_ value: Double?) -> String {
        guard let value else { return "--" }
        if value == value.rounded() {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    // MARK: - Unsynced Banner

    private var unsyncedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("\(unsyncedLiveCount) live app\(unsyncedLiveCount == 1 ? "" : "s") not on the wall")
                .font(.callout.weight(.medium))
            Button("Sync Now") {
                presentSyncSheet()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(20)
    }

    // MARK: - App Card

    private func appCard(app: AppWallApp) -> some View {
        VStack(spacing: 8) {
            appIcon(app: app)

            HStack(spacing: 3) {
                stateIcon(for: app.currentState)
                    .font(.system(size: 9))
                Text(app.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func appIcon(app: AppWallApp) -> some View {
        if let iconURLString = app.iconUrl, let iconURL = URL(string: iconURLString) {
            AsyncImage(url: iconURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                default:
                    iconPlaceholder
                }
            }
        } else {
            iconPlaceholder
        }
    }

    private var iconPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: 56, height: 56)
            Image(systemName: "app")
                .font(.system(size: 24))
                .foregroundStyle(Color.accentColor.opacity(0.6))
        }
    }

    @ViewBuilder
    private func stateIcon(for state: String?) -> some View {
        switch state?.lowercased() {
        case "ready_for_sale":
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case "waiting_for_review", "in_review":
            Image(systemName: "clock.fill")
                .foregroundStyle(.orange)
        case "rejected":
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    // MARK: - Data Loading

    private func loadSummary() async {
        guard !isSummaryLoading else { return }
        isSummaryLoading = true
        defer { isSummaryLoading = false }
        do {
            summary = try await AppWallService.shared.fetchSummary()
        } catch {
            Log("[AppWall] summary fetch failed: \(error.localizedDescription)")
        }
    }

    private func loadApps() async {
        await loadApps(reset: true)
    }

    private func loadApps(reset: Bool) async {
        if reset {
            guard !isLoading else { return }
            isLoading = true
        } else {
            guard !isLoading && !isLoadingNextPage && hasMorePages else { return }
            isLoadingNextPage = true
        }
        loadError = nil
        defer {
            if reset {
                isLoading = false
            } else {
                isLoadingNextPage = false
            }
        }

        do {
            let response = try await AppWallService.shared.fetchWallApps(
                limit: 50,
                offset: reset ? 0 : apps.count
            )
            totalCount = response.total
            if reset {
                apps = response.items
            } else {
                apps.append(contentsOf: response.items)
            }
        } catch {
            loadError = error.localizedDescription
        }
    }
}

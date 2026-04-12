import SwiftUI

/// Synthesized single-app dashboard for the App > Overview sub-tab.
///
/// Five sections, each a card or block:
///   1. Listing health
///   2. Version state
///   3. Screenshots
///   4. Activity
///   5. Local source
struct ASCOverview: View {
    var appState: AppState

    private var asc: ASCManager { appState.ascManager }
    @State private var showPreview = false
    @State private var showBundleIDSelector = false
    @State private var viewedKey: String?

    private var selectedVersionBinding: Binding<String> {
        Binding(
            get: { asc.selectedVersion?.id ?? "" },
            set: { newValue in
                guard !newValue.isEmpty else { return }
                asc.prepareForVersionSelection(newValue)
                Task { await asc.refreshTabData(.app) }
            }
        )
    }

    var body: some View {
        ASCCredentialGate(
            appState: appState,
            ascManager: asc,
            projectId: appState.activeProjectId ?? (asc.app?.id ?? ""),
            bundleId: appState.activeProject?.metadata.bundleIdentifier ?? asc.app?.bundleId
        ) {
            ASCTabContent(
                appState: appState,
                asc: asc,
                tab: .app,
                platform: appState.activeProject?.platform ?? .iOS,
                allowWithoutLocalProject: true
            ) {
                overviewContent
            }
        }
        .task(id: "\(appState.activeProjectId ?? ""):\(asc.credentialActivationRevision)") {
            await asc.ensureTabData(.app)
        }
        .task(id: asc.app?.id ?? "") {
            // Fire app_viewed once per (app, tab-entry) — not on every redraw.
            guard let appId = asc.app?.id, viewedKey != appId else { return }
            viewedKey = appId
        }
        .sheet(isPresented: $showPreview) {
            SubmitPreviewSheet(appState: appState)
        }
        .onChange(of: asc.showSubmitPreview) { _, newValue in
            if newValue {
                showPreview = true
                asc.showSubmitPreview = false
            }
        }
    }

    @ViewBuilder
    private var overviewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerRow

                if asc.app != nil {
                    ASCVersionPickerBar(
                        asc: asc,
                        selection: selectedVersionBinding,
                        onCreateUpdate: { asc.showCreateUpdateSheet = true }
                    )
                }

                Divider()

                // Version stats + rejection card (original position)
                versionStatsSection

                // Submission Readiness (original standalone list)
                submissionReadinessSection

                // 1. Listing health
                listingHealthCard

                // 2. Screenshots
                screenshotsCard

                // 3. Activity
                activityCard

                // 4. Local source
                localSourceCard
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    // MARK: - Header row

    @ViewBuilder
    private var headerRow: some View {
        HStack {
            Text("Overview")
                .font(.title2.weight(.semibold))
            Spacer()
            ASCTabRefreshButton(asc: asc, tab: .app, helpText: "Refresh overview data")
        }

        if let app = asc.app {
            HStack(spacing: 10) {
                if let project = appState.activeProject {
                    ProjectAppIconView(project: project, size: 40, cornerRadius: 9) {
                        fallbackAppIcon(name: app.name)
                    }
                } else {
                    fallbackAppIcon(name: app.name)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.headline)
                    HStack(spacing: 4) {
                        Text(app.bundleId)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fontDesign(.monospaced)
                        if appState.activeProject != nil {
                            Button {
                                showBundleIDSelector = true
                            } label: {
                                Image(systemName: "gearshape")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showBundleIDSelector, arrowEdge: .bottom) {
                                ProjectBundleIDSelectorView(
                                    appState: appState,
                                    asc: asc,
                                    tab: .app,
                                    platform: appState.activeProject?.platform ?? .iOS,
                                    subtitle: "Switch which bundle ID this project uses for App Store Connect. This is useful for multi-target projects that ship different app, extension, or test bundle identifiers.",
                                    standalone: false
                                )
                                .frame(width: 480)
                            }
                        }
                    }
                }
            }
        }
    }

    private func fallbackAppIcon(name: String) -> some View {
        let first = String(name.prefix(1)).uppercased()
        return ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.accentColor.opacity(0.18))
                .frame(width: 40, height: 40)
            Text(first.isEmpty ? "?" : first)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.8))
        }
    }

    // MARK: - 1. Listing Health

    private enum ListingHealthKind { case missing, short, complete, optimized }

    private struct ListingHealthRow: Identifiable {
        let id: String
        let label: String
        let value: String?
        let kind: ListingHealthKind
    }

    private var listingHealthRows: [ListingHealthRow] {
        let versionLoc = asc.primaryVersionLocalization()
        let infoLoc = asc.primaryAppInfoLocalization()

        func trimmed(_ value: String?) -> String? {
            let t = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t?.isEmpty ?? true) ? nil : t
        }

        func text(_ length: Int, short: Int, optimized: Int) -> ListingHealthKind {
            if length == 0 { return .missing }
            if length < short { return .short }
            if length >= optimized { return .optimized }
            return .complete
        }

        let title = trimmed(versionLoc?.attributes.title) ?? trimmed(infoLoc?.attributes.name)
        let subtitle = trimmed(infoLoc?.attributes.subtitle)
        let description = trimmed(versionLoc?.attributes.description)
        let keywords = trimmed(versionLoc?.attributes.keywords)
        let category = trimmed(asc.appInfo?.primaryCategoryId)?.replacingOccurrences(of: "_", with: " ").capitalized
        let privacyPolicy = trimmed(infoLoc?.attributes.privacyPolicyUrl)
        let ageRating = asc.ageRatingDeclaration != nil ? "Set" : nil

        return [
            ListingHealthRow(
                id: "title",
                label: "Title",
                value: title,
                kind: title == nil ? .missing : (title!.count >= 20 ? .optimized : .complete)
            ),
            ListingHealthRow(
                id: "subtitle",
                label: "Subtitle",
                value: subtitle,
                kind: subtitle == nil ? .missing : (subtitle!.count >= 20 ? .optimized : .short)
            ),
            ListingHealthRow(
                id: "description",
                label: "Description",
                value: description,
                kind: text(description?.count ?? 0, short: 200, optimized: 1500)
            ),
            ListingHealthRow(
                id: "keywords",
                label: "Keywords",
                value: keywords,
                kind: text(keywords?.count ?? 0, short: 30, optimized: 80)
            ),
            ListingHealthRow(
                id: "category",
                label: "Category",
                value: category,
                kind: category == nil ? .missing : .complete
            ),
            ListingHealthRow(
                id: "age",
                label: "Age Rating",
                value: ageRating,
                kind: ageRating == nil ? .missing : .complete
            ),
            ListingHealthRow(
                id: "privacy",
                label: "Privacy Policy URL",
                value: privacyPolicy,
                kind: privacyPolicy == nil ? .missing : .complete
            ),
            ListingHealthRow(
                id: "icon",
                label: "App Icon",
                value: asc.appIconStatus,
                kind: asc.appIconStatus == nil ? .missing : .complete
            ),
        ]
    }

    private var listingHealthCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(.blue)
                Text("Listing Health")
                    .font(.headline)
                Spacer()
                Text(listingHealthSummaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(Array(listingHealthRows.enumerated()), id: \.element.id) { idx, row in
                    listingHealthRowView(row)
                    if idx < listingHealthRows.count - 1 {
                        Divider().padding(.leading, 12)
                    }
                }
            }
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var listingHealthSummaryText: String {
        let rows = listingHealthRows
        let missing = rows.filter { $0.kind == .missing }.count
        let short = rows.filter { $0.kind == .short }.count
        if missing == 0 && short == 0 {
            return "All set"
        }
        var parts: [String] = []
        if missing > 0 { parts.append("\(missing) missing") }
        if short > 0 { parts.append("\(short) short") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func listingHealthRowView(_ row: ListingHealthRow) -> some View {
        HStack {
            listingHealthIcon(for: row.kind)
                .font(.callout)
            Text(row.label)
                .font(.callout)
            Spacer()
            Text(row.value.map { truncate($0, limit: 40) } ?? listingHealthPlaceholder(for: row.kind))
                .font(.callout)
                .foregroundStyle(row.kind == .missing ? .red : .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func listingHealthIcon(for kind: ListingHealthKind) -> some View {
        switch kind {
        case .missing:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .short:
            Image(systemName: "arrow.up.right.circle.fill").foregroundStyle(.orange)
        case .complete:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .optimized:
            Image(systemName: "sparkles").foregroundStyle(.blue)
        }
    }

    private func listingHealthPlaceholder(for kind: ListingHealthKind) -> String {
        switch kind {
        case .missing: return "Not set"
        case .short: return "Short"
        case .complete: return "Complete"
        case .optimized: return "Optimized"
        }
    }

    private func truncate(_ value: String, limit: Int) -> String {
        value.count > limit ? String(value.prefix(limit)) + "…" : value
    }

    @ViewBuilder
    private func submissionReadinessRow(_ field: SubmissionReadiness.FieldStatus) -> some View {
        HStack {
            if field.label == "Build" && asc.buildPipelinePhase != .idle {
                ProgressView().controlSize(.small)
                Text(field.label).font(.callout).foregroundStyle(.orange)
            } else if field.isLoading {
                ProgressView().controlSize(.small)
                Text(field.label).font(.callout).foregroundStyle(.secondary)
            } else if field.required && (field.value == nil || field.value!.isEmpty) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).font(.callout)
                Text(field.label).font(.callout).foregroundStyle(.red)
            } else if !field.required && (field.value == nil || field.value!.isEmpty) {
                Image(systemName: "arrow.up.right.circle").foregroundStyle(.orange).font(.callout)
                Text(field.label).font(.callout).foregroundStyle(.orange)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                Text(field.label).font(.callout)
            }
            Spacer()
            if field.label == "Build" && asc.buildPipelinePhase != .idle {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(asc.buildPipelinePhase.rawValue)
                        .font(.callout)
                        .foregroundStyle(.orange)
                    ProgressView(value: buildProgress)
                        .tint(.orange)
                        .frame(width: 120)
                    if !asc.buildPipelineMessage.isEmpty {
                        Text(asc.buildPipelineMessage)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .frame(maxWidth: 200, alignment: .trailing)
                    }
                }
            } else if field.isLoading {
                Text("Loading…").font(.callout).foregroundStyle(.secondary)
            } else if let url = field.actionUrl, let nsUrl = URL(string: url) {
                if field.label != "Privacy Nutrition Labels" {
                    Button {
                        launchAIFixForField(field)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "sparkles")
                            Text("Fix")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button("Open in Web") {
                    NSWorkspace.shared.open(nsUrl)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if field.required && (field.value == nil || field.value!.isEmpty) {
                Button {
                    launchAIFixForField(field)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles")
                        Text("Fix")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Text(field.value ?? "—")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    // MARK: - Version Stats (original position — flat, not carded)

    @ViewBuilder
    private var versionStatsSection: some View {
        let live = asc.liveVersion
        let pending = asc.currentUpdateVersion
        let rejectionCardVersion = asc.rejectionCardVersionForSelectedVersion(
            from: asc.appStoreVersions
        )

        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
            spacing: 8
        ) {
            metricCard(
                title: "Live Version",
                value: live?.attributes.versionString ?? "—",
                subtitle: live != nil ? "Ready for Sale" : "None",
                color: live != nil ? .green : .secondary,
                icon: "checkmark.seal.fill"
            )
            metricCard(
                title: "Pending",
                value: pending?.attributes.versionString ?? "—",
                subtitle: pending.map { stateLabel($0.attributes.appStoreState ?? "") } ?? "None",
                color: pending != nil ? .orange : .secondary,
                icon: "clock.fill"
            )
            metricCard(
                title: "Total Versions",
                value: "\(asc.appStoreVersions.count)",
                subtitle: "All time",
                color: .blue,
                icon: "list.number"
            )
        }

        if let rejectionCardVersion {
            RejectionCardView(asc: asc, version: rejectionCardVersion) {
                HStack {
                    Spacer()
                    Button("Prepare Re-submission") {
                        showPreview = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
        }
    }

    // MARK: - Submission Readiness (original standalone list)

    private var submissionReadinessSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Submission Readiness")
                    .font(.headline)

                Spacer()
                let activeUpdateState = asc.currentUpdateVersion?.attributes.appStoreState ?? ""
                let showStatus = asc.currentUpdateVersion != nil && !ASCReleaseStatus.isEditable(activeUpdateState)

                if asc.canCreateUpdate {
                    Button("Create Update") {
                        asc.showCreateUpdateSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(showStatus ? "View Status" : "Submit for Review") {
                        showPreview = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!showStatus && !asc.submissionReadiness.isComplete)
                }
            }

            VStack(spacing: 0) {
                ForEach(asc.submissionReadiness.fields) { field in
                    submissionReadinessRow(field)
                    Divider().padding(.leading, 12)
                }
            }
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - 3. Screenshots

    private var screenshotsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "photo.on.rectangle.angled")
                    .foregroundStyle(.pink)
                Text("Screenshots")
                    .font(.headline)
                Spacer()
                Button("Generate new screenshots") {
                    // Slot for the sibling screenshot-generation workstream.
                    appState.activeTab = .screenshots
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Manage") {
                    appState.activeTab = .screenshots
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            let screenshots = screenshotsForPreview
            if screenshots.isEmpty {
                Text("No screenshots uploaded yet for the primary locale.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(screenshots, id: \.id) { shot in
                            screenshotThumbnail(shot)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Flatten all screenshots for the primary locale into a single preview row.
    private var screenshotsForPreview: [ASCScreenshot] {
        let locale = asc.primaryAppInformationLocale()
            ?? asc.screenshotsByLocale.keys.first
        guard let locale,
              let setMap = asc.screenshotsByLocale[locale] else { return [] }
        // Preserve a stable order by iterating over the known sets for the locale.
        let sets = asc.screenshotSetsByLocale[locale] ?? []
        var result: [ASCScreenshot] = []
        for set in sets {
            if let shots = setMap[set.id] { result.append(contentsOf: shots) }
        }
        // Fall back to any orphan screenshot keys that weren't matched above.
        for (key, shots) in setMap where !sets.contains(where: { $0.id == key }) {
            result.append(contentsOf: shots)
        }
        return Array(result.prefix(12))
    }

    private func screenshotThumbnail(_ shot: ASCScreenshot) -> some View {
        Group {
            if let url = shot.imageURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fit)
                    case .failure:
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    default:
                        ProgressView().controlSize(.small)
                    }
                }
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 90, height: 160)
        .background(.background.tertiary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 4. Activity

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.teal)
                Text("Activity")
                    .font(.headline)
                Spacer()
            }

            if asc.submissionHistoryEvents.isEmpty {
                Text("No recent submission activity.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(asc.submissionHistoryEvents.prefix(15).enumerated()), id: \.element.id) { idx, entry in
                        submissionHistoryRow(entry)
                        if idx < min(14, asc.submissionHistoryEvents.count - 1) {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .background(.background.tertiary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 5. Local Source

    private var localSourceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "folder.fill.badge.gearshape")
                    .foregroundStyle(.orange)
                Text("Local Source")
                    .font(.headline)
                Spacer()
            }

            if let project = appState.activeProject {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: localProjectIcon(project))
                            .foregroundStyle(.secondary)
                        Text(project.name)
                            .font(.callout.weight(.medium))
                        Spacer()
                        Text(project.type.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                    Text(project.path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let latestBuild = latestLocalBuildLabel {
                        Text("Latest build: \(latestBuild)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Button("Build & Upload") {
                            asc.showSubmitPreview = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        Button("Open in Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.top, 2)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No local project is linked to this app yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button {
                        appState.showImportProjectSheet = true
                    } label: {
                        Label("Link project…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var latestLocalBuildLabel: String? {
        // Prefer the newest ASC build that corresponds to this app — same data
        // the Builds tab already uses.
        guard let newest = asc.builds.first else { return nil }
        let version = newest.attributes.version
        if let uploaded = newest.attributes.uploadedDate, !uploaded.isEmpty {
            return "\(version) · \(ascShortDate(uploaded))"
        }
        return version.isEmpty ? nil : version
    }

    private func localProjectIcon(_ project: Project) -> String {
        if project.platform == .macOS { return "desktopcomputer" }
        switch project.type {
        case .reactNative: return "atom"
        case .swift: return "swift"
        case .flutter: return "bird"
        }
    }

    // MARK: - Shared helpers

    private func launchAIFixForField(_ field: SubmissionReadiness.FieldStatus) {
        guard let appId = asc.app?.id else { return }

        let prompt: String
        if let hint = field.hint {
            prompt = "Fix the \"\(field.label)\" submission readiness issue for app \(appId): \(hint)"
        } else {
            prompt = "Fix the \"\(field.label)\" submission readiness issue for app \(appId). "
                + "This field is currently missing or incomplete. Use the App Store Connect MCP tools to resolve it."
        }

        var projectPath: String? = nil
        if let projectId = asc.loadedProjectId {
            projectPath = ProjectStorage().baseDirectory.appendingPathComponent(projectId).path
        }

        let settings = SettingsService.shared
        let agent = AIAgent(rawValue: settings.defaultAgentCLI) ?? .claudeCode
        let terminal = settings.resolveDefaultTerminal().terminal

        if terminal.isBuiltIn {
            appState.showTerminal = true
            appState.terminalManager.createAgentSession(
                projectPath: projectPath,
                agent: agent,
                prompt: prompt,
                skipPermissions: settings.skipAgentPermissions
            )
        } else {
            TerminalLauncher.launch(projectPath: projectPath, agent: agent, terminal: terminal, prompt: prompt, skipPermissions: settings.skipAgentPermissions)
        }
    }

    private var buildProgress: Double {
        switch asc.buildPipelinePhase {
        case .idle: return 0
        case .signingSetup: return 0.1
        case .archiving: return 0.3
        case .exporting: return 0.55
        case .uploading: return 0.75
        case .processing: return 0.9
        }
    }

    private func metricCard(title: String, value: String, subtitle: String, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.callout).foregroundStyle(color)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value).font(.body.weight(.semibold))
            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.tertiary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func submissionHistoryRow(_ event: ASCSubmissionHistoryEvent) -> some View {
        HStack {
            Text(event.versionString)
                .font(.body.weight(.medium))
                .frame(width: 80, alignment: .leading)
            submissionEventBadge(event.eventType)
            Spacer()
            Text(ascLongDate(event.occurredAt))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func submissionEventBadge(_ eventType: ASCSubmissionHistoryEventType) -> some View {
        let (label, color) = submissionEventStyle(eventType)
        return Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func stateLabel(_ state: String) -> String {
        state.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func submissionEventStyle(_ eventType: ASCSubmissionHistoryEventType) -> (String, Color) {
        switch eventType {
        case .submitted:
            return ("Submitted", .blue)
        case .submissionError:
            return ("Submission Error", .red)
        case .inReview:
            return ("In Review", .blue)
        case .processing:
            return ("Processing", .orange)
        case .accepted:
            return ("Accepted", .green)
        case .live:
            return ("Live", .green)
        case .rejected:
            return ("Rejected", .red)
        case .withdrawn:
            return ("Withdrawn", .orange)
        case .removed:
            return ("Removed", .secondary)
        }
    }
}


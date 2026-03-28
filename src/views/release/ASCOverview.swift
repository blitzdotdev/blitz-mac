import SwiftUI

struct ASCOverview: View {
    var appState: AppState

    private var asc: ASCManager { appState.ascManager }
    @State private var showPreview = false

    var body: some View {
        ASCCredentialGate(
            appState: appState,
            ascManager: asc,
            projectId: appState.activeProjectId ?? "",
            bundleId: appState.activeProject?.metadata.bundleIdentifier
        ) {
            ASCTabContent(appState: appState, asc: asc, tab: .app, platform: appState.activeProject?.platform ?? .iOS) {
                overviewContent
            }
        }
        .task(id: "\(appState.activeProjectId ?? ""):\(asc.credentialActivationRevision)") {
            await asc.ensureTabData(.app)
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
            VStack(alignment: .leading, spacing: 12) {
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
                                Image(systemName: "app.fill")
                                    .font(.system(size: 30))
                                    .foregroundStyle(.blue)
                                    .frame(width: 40, height: 40)
                            }
                        } else {
                            Image(systemName: "app.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(.blue)
                                .frame(width: 40, height: 40)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                                .font(.headline)
                            Text(app.bundleId)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fontDesign(.monospaced)
                        }
                    }
                }

                Divider()

                let live = asc.appStoreVersions.first { $0.attributes.appStoreState == "READY_FOR_SALE" }
                let pending = asc.appStoreVersions.first {
                    let s = $0.attributes.appStoreState ?? ""
                    return s != "READY_FOR_SALE" && s != "REMOVED_FROM_SALE"
                        && s != "DEVELOPER_REMOVED_FROM_SALE" && !s.isEmpty
                }
                let feedbackVersion = asc.feedbackDisplayVersion(from: asc.appStoreVersions)

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

                // Rejection detail — shown when there's rejection data (persists until a new version is approved)
                if let feedbackVersion {
                    RejectionCardView(asc: asc, version: feedbackVersion) {
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

                // Preview / Submit section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Submission Readiness")
                            .font(.headline)

                        Spacer()
                        let versionState = asc.appStoreVersions.first(where: {
                            let s = $0.attributes.appStoreState ?? ""
                            return s != "READY_FOR_SALE" && s != "REMOVED_FROM_SALE"
                                && s != "DEVELOPER_REMOVED_FROM_SALE" && !s.isEmpty
                        })?.attributes.appStoreState ?? ""
                        let alreadySubmitted = ["WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_DEVELOPER_RELEASE"]
                            .contains(versionState)

                        Button(alreadySubmitted ? "View Status" : "Submit for Review") {
                            showPreview = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!alreadySubmitted && !asc.submissionReadiness.isComplete)
                    }

                    VStack(spacing: 0) {
                        ForEach(asc.submissionReadiness.fields) { field in
                            HStack {
                                if field.label == "Build" && asc.buildPipelinePhase != .idle {
                                    // Show build progress inline
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(field.label)
                                        .font(.callout)
                                        .foregroundStyle(.orange)
                                } else if field.isLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(field.label)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                } else if field.required && (field.value == nil || field.value!.isEmpty) {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .foregroundStyle(.red)
                                        .font(.callout)
                                    Text(field.label)
                                        .font(.callout)
                                        .foregroundStyle(.red)
                                } else if !field.required && (field.value == nil || field.value!.isEmpty) {
                                    Image(systemName: "arrow.up.right.circle")
                                        .foregroundStyle(.orange)
                                        .font(.callout)
                                    Text(field.label)
                                        .font(.callout)
                                        .foregroundStyle(.orange)
                                } else {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.callout)
                                    Text(field.label)
                                        .font(.callout)
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
                                    Text("Loading…")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
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
                            Divider().padding(.leading, 12)
                        }
                    }
                    .background(.background.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                if !asc.submissionHistoryEvents.isEmpty {
                    Text("Submission History")
                        .font(.headline)
                        .padding(.top, 4)

                    VStack(spacing: 0) {
                        ForEach(Array(asc.submissionHistoryEvents.prefix(15).enumerated()), id: \.element.id) { idx, entry in
                            submissionHistoryRow(entry)
                            if idx < min(14, asc.submissionHistoryEvents.count - 1) {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                    .background(.background.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

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
            let session = appState.terminalManager.createSession(projectPath: projectPath)
            let command = TerminalLauncher.buildAgentCommand(
                projectPath: projectPath,
                agent: agent,
                prompt: prompt,
                skipPermissions: settings.skipAgentPermissions
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                session.sendCommand(command)
            }
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
        .background(.background.secondary)
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

    private func stateColor(_ state: String) -> (String, Color) {
        switch state {
        case "READY_FOR_SALE": return ("Live", .green)
        case "PROCESSING": return ("Processing", .orange)
        case "PENDING_DEVELOPER_RELEASE": return ("Pending Release", .yellow)
        case "IN_REVIEW": return ("In Review", .blue)
        case "WAITING_FOR_REVIEW": return ("Waiting", .blue)
        case "INVALID_BINARY": return ("Submission Error", .red)
        case "REJECTED": return ("Rejected", .red)
        case "DEVELOPER_REJECTED": return ("Dev Rejected", .orange)
        case "DEVELOPER_REMOVED_FROM_SALE": return ("Removed", .secondary)
        default: return (stateLabel(state), .secondary)
        }
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

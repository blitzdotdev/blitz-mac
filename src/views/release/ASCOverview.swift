import SwiftUI

struct ASCOverview: View {
    var appState: AppState

    private var asc: ASCManager { appState.ascManager }
    @State private var showPreview = false
    @State private var appIcon: NSImage?
    @State private var showAppleIDLogin = false

    var body: some View {
        ASCCredentialGate(
            ascManager: asc,
            projectId: appState.activeProjectId ?? "",
            bundleId: appState.activeProject?.metadata.bundleIdentifier
        ) {
            ASCTabContent(asc: asc, tab: .ascOverview, platform: appState.activeProject?.platform ?? .iOS) {
                overviewContent
            }
        }
        .task(id: appState.activeProjectId) {
            if let pid = appState.activeProjectId {
                asc.checkAppIcon(projectId: pid)
                appIcon = Self.loadAppIcon(projectId: pid)
            }
            await asc.fetchTabData(.ascOverview)
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
        .sheet(isPresented: $showAppleIDLogin) {
            AppleIDLoginSheet { session in
                asc.setIrisSession(session)
                Task { await asc.fetchRejectionFeedback() }
            }
        }
        .onChange(of: asc.showAppleIDLogin) { _, newValue in
            if newValue {
                showAppleIDLogin = true
                asc.showAppleIDLogin = false
            }
        }
        .onChange(of: asc.appStoreVersions.map(\.id)) { _, _ in
            guard let appId = asc.app?.id else { return }
            let rejectedVersion = asc.appStoreVersions.first(where: {
                $0.attributes.appStoreState == "REJECTED"
            })
            guard let version = rejectedVersion else { return }

            // Always try cache first — instant, no auth needed
            asc.loadCachedFeedback(appId: appId, versionString: version.attributes.versionString)

            // Then try live fetch if we have a session
            asc.loadIrisSession()
            if asc.irisSessionState == .valid {
                Task { await asc.fetchRejectionFeedback() }
            }
        }
    }

    @ViewBuilder
    private var overviewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let app = asc.app {
                    HStack(spacing: 10) {
                        if let icon = appIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 9))
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

                // Rejection detail — shown when the pending version was rejected
                if let pending, pending.attributes.appStoreState == "REJECTED" {
                    rejectionCard(version: pending)
                }

                // Preview / Submit section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Submission Readiness")
                            .font(.headline)

                        Button {
                            Task { await asc.refreshTabData(.ascOverview) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh submission readiness")

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
                                } else if let url = field.actionUrl, let nsUrl = URL(string: url) {
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

                if !asc.appStoreVersions.isEmpty {
                    Text("Version History")
                        .font(.headline)
                        .padding(.top, 4)

                    VStack(spacing: 0) {
                        ForEach(Array(asc.appStoreVersions.prefix(15).enumerated()), id: \.element.id) { idx, version in
                            versionRow(version)
                            if idx < min(14, asc.appStoreVersions.count - 1) {
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
        let terminal = TerminalApp.from(settings.defaultTerminal)
        TerminalLauncher.launch(projectPath: projectPath, agent: agent, terminal: terminal, prompt: prompt, skipPermissions: settings.skipAgentPermissions)
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

    private func versionRow(_ version: ASCAppStoreVersion) -> some View {
        HStack {
            Text(version.attributes.versionString)
                .font(.body.weight(.medium))
                .frame(width: 80, alignment: .leading)
            stateBadge(version.attributes.appStoreState ?? "Unknown")
            Spacer()
            if let date = version.attributes.createdDate {
                Text(ascShortDate(date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func stateBadge(_ state: String) -> some View {
        let (label, color) = stateColor(state)
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
        case "REJECTED": return ("Rejected", .red)
        case "DEVELOPER_REJECTED": return ("Dev Rejected", .orange)
        case "DEVELOPER_REMOVED_FROM_SALE": return ("Removed", .secondary)
        default: return (stateLabel(state), .secondary)
        }
    }

    // MARK: - Rejection Card

    @ViewBuilder
    private func rejectionCard(version: ASCAppStoreVersion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Version \(version.attributes.versionString) Rejected")
                        .font(.headline)
                    if let date = version.attributes.createdDate {
                        Text("Submitted \(ascShortDate(date))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }


            // Submission history from API
            if !asc.reviewSubmissions.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Review History")
                        .font(.callout.weight(.semibold))

                    ForEach(asc.reviewSubmissions.prefix(5)) { submission in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(submissionStateColor(submission.attributes.state ?? ""))
                                .frame(width: 8, height: 8)
                            Text(submissionStateLabel(submission.attributes.state ?? ""))
                                .font(.callout)
                            Spacer()
                            if let date = submission.attributes.submittedDate {
                                Text(ascShortDate(date))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            // Submission item details
            if !asc.latestSubmissionItems.isEmpty {
                let rejected = asc.latestSubmissionItems.filter { $0.attributes.state == "REJECTED" }
                let accepted = asc.latestSubmissionItems.filter { $0.attributes.state == "ACCEPTED" || $0.attributes.state == "APPROVED" }

                if !rejected.isEmpty || !accepted.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Review Items")
                            .font(.callout.weight(.semibold))

                        ForEach(asc.latestSubmissionItems) { item in
                            HStack(spacing: 8) {
                                Image(systemName: item.attributes.state == "REJECTED" ? "xmark.circle.fill" : "checkmark.circle.fill")
                                    .foregroundStyle(item.attributes.state == "REJECTED" ? .red : .green)
                                    .font(.caption)
                                Text(item.attributes.state?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Unknown")
                                    .font(.callout)
                                if item.attributes.resolved == true {
                                    Text("Resolved")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.green.opacity(0.15))
                                        .foregroundStyle(.green)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
            }
            
            // What was submitted (review detail context)
            if let rd = asc.reviewDetail {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Submitted Review Info")
                        .font(.callout.weight(.semibold))

                    if let notes = rd.attributes.notes, !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Your Notes to Apple")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(notes)
                                .font(.callout)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.background.tertiary)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }

                    if rd.attributes.demoAccountRequired == true {
                        HStack(spacing: 6) {
                            Image(systemName: "person.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Demo account: \(rd.attributes.demoAccountName ?? "—")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let contact = rd.attributes.contactEmail {
                        HStack(spacing: 6) {
                            Image(systemName: "envelope")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Contact: \(rd.attributes.contactFirstName ?? "") \(rd.attributes.contactLastName ?? "") (\(contact))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Apple's Feedback (from iris API)
            appleFeedbackSection()

            // Re-submit action
            HStack {
                Spacer()
                Button("Prepare Re-submission") {
                    showPreview = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(16)
        .background(Color.red.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.red.opacity(0.15), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func appleFeedbackSection() -> some View {
        let hasLiveData = !asc.rejectionReasons.isEmpty || !asc.rejectionMessages.isEmpty
        let hasCache = asc.cachedFeedback != nil

        Divider()

        VStack(alignment: .leading, spacing: 10) {
            Text("Apple's Feedback")
                .font(.callout.weight(.semibold))

            if asc.isLoadingIrisFeedback {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading feedback…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if hasLiveData {
                liveFeedbackView()
            } else if hasCache {
                cachedFeedbackView(asc.cachedFeedback!)
            } else if let error = asc.irisFeedbackError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                signInPrompt()
            } else {
                signInPrompt()
            }
        }
    }

    @ViewBuilder
    private func signInPrompt() -> some View {
        switch asc.irisSessionState {
        case .noSession, .unknown:
            HStack(spacing: 10) {
                Image(systemName: "person.badge.key")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Sign in with your Apple ID to see Apple's detailed review feedback.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Sign In") { showAppleIDLogin = true }
                    .buttonStyle(.bordered)
            }
            .padding(10)
            .background(.background.tertiary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        case .expired:
            HStack(spacing: 10) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.title3)
                    .foregroundStyle(.orange)
                Text("Apple ID session expired.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Sign In Again") { showAppleIDLogin = true }
                    .buttonStyle(.bordered)
            }
            .padding(10)
            .background(.background.tertiary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        case .valid:
            Text("No rejection feedback found in the Resolution Center.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func liveFeedbackView() -> some View {
        if !asc.rejectionReasons.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(asc.rejectionReasons) { rejection in
                    ForEach(rejection.attributes.reasons ?? [], id: \.reasonCode) { reason in
                        reasonCard(section: reason.reasonSection, description: reason.reasonDescription, code: reason.reasonCode)
                    }
                }
            }
        }
        if !asc.rejectionMessages.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Reviewer Messages")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(asc.rejectionMessages) { msg in
                    messageCard(body: msg.attributes.messageBody.map { htmlToPlainText($0) }, date: msg.attributes.createdDate)
                }
            }
        }
    }

    @ViewBuilder
    private func cachedFeedbackView(_ cache: IrisFeedbackCache) -> some View {
        if !cache.reasons.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(cache.reasons, id: \.code) { reason in
                    reasonCard(section: reason.section, description: reason.description, code: reason.code)
                }
            }
        }
        if !cache.messages.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Reviewer Messages")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(cache.messages, id: \.body) { msg in
                    messageCard(body: msg.body, date: msg.date)
                }
            }
        }
        Text("Last fetched \(ascLongDate(ISO8601DateFormatter().string(from: cache.fetchedAt)))")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    private func reasonCard(section: String?, description: String?, code: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let section, !section.isEmpty {
                Text(section)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.red)
            }
            if let desc = description, !desc.isEmpty {
                Text(desc)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            if let code, !code.isEmpty {
                Text("Code: \(code)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.tertiary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func messageCard(body: String?, date: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let body, !body.isEmpty {
                Text(body)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            if let date {
                Text(ascLongDate(date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.tertiary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func submissionStateColor(_ state: String) -> Color {
        switch state {
        case "COMPLETE": return .green
        case "IN_PROGRESS", "WAITING_FOR_REVIEW": return .blue
        case "CANCELING": return .orange
        default: return .secondary
        }
    }

    private func submissionStateLabel(_ state: String) -> String {
        switch state {
        case "COMPLETE": return "Review Complete"
        case "IN_PROGRESS": return "In Progress"
        case "WAITING_FOR_REVIEW": return "Waiting for Review"
        case "CANCELING": return "Canceling"
        default: return state.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func loadAppIcon(projectId: String) -> NSImage? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let blitzPath = "\(home)/.blitz/projects/\(projectId)/assets/AppIcon/icon_1024.png"
        if let image = NSImage(contentsOfFile: blitzPath) { return image }

        let projectDir = "\(home)/.blitz/projects/\(projectId)"
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: projectDir) else { return nil }
        while let file = enumerator.nextObject() as? String {
            guard file.hasSuffix("AppIcon.appiconset/Contents.json") else { continue }
            let contentsPath = "\(projectDir)/\(file)"
            guard let data = fm.contents(atPath: contentsPath),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let images = json["images"] as? [[String: Any]] else { continue }
            for entry in images {
                if let filename = entry["filename"] as? String {
                    let iconDir = (contentsPath as NSString).deletingLastPathComponent
                    if let image = NSImage(contentsOfFile: "\(iconDir)/\(filename)") { return image }
                }
            }
        }
        return nil
    }
}

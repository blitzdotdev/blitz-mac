import SwiftUI

struct ASCOverview: View {
    var appState: AppState

    private var asc: ASCManager { appState.ascManager }
    @State private var showPreview = false

    var body: some View {
        ASCCredentialGate(
            ascManager: asc,
            projectId: appState.activeProjectId ?? "",
            bundleId: appState.activeProject?.metadata.bundleIdentifier
        ) {
            ASCTabContent(asc: asc, tab: .ascOverview) {
                overviewContent
            }
        }
        .task {
            if let pid = appState.activeProjectId {
                asc.checkAppIcon(projectId: pid)
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
    }

    @ViewBuilder
    private var overviewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let app = asc.app {
                    HStack(spacing: 16) {
                        Image(systemName: "app.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.blue)
                            .frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name)
                                .font(.title2.weight(.semibold))
                            Text(app.bundleId)
                                .font(.body)
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
                    spacing: 16
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

                // Preview / Submit section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Submission Readiness")
                            .font(.headline)
                        Spacer()
                        Button("Submit for Review") {
                            showPreview = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!asc.submissionReadiness.isComplete)
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
                                    Button("Open in Web") {
                                        NSWorkspace.shared.open(nsUrl)
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
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            Divider().padding(.leading, 16)
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
            .padding(24)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(color)
                Text(title).font(.callout).foregroundStyle(.secondary)
            }
            Text(value).font(.title2.weight(.semibold))
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
        case "DEVELOPER_REMOVED_FROM_SALE": return ("Removed", .secondary)
        default: return (stateLabel(state), .secondary)
        }
    }
}

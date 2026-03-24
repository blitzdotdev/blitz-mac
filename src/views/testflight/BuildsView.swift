import SwiftUI

struct BuildsView: View {
    var appState: AppState

    private var asc: ASCManager { appState.ascManager }
    @State private var selectedBuildId: String?

    var body: some View {
        ASCCredentialGate(
            ascManager: asc,
            projectId: appState.activeProjectId ?? "",
            bundleId: appState.activeProject?.metadata.bundleIdentifier
        ) {
            ASCTabContent(asc: asc, tab: .builds, platform: appState.activeProject?.platform ?? .iOS) {
                buildsContent
            }
        }
        .task(id: appState.activeProjectId) { await asc.ensureTabData(.builds) }
        .onAppear { syncSelectedBuild() }
        .onChange(of: asc.builds.map(\.id)) { _, _ in syncSelectedBuild() }
    }

    @ViewBuilder
    private var buildsContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Builds")
                    .font(.title2.weight(.semibold))
                Spacer()
                ASCTabRefreshButton(asc: asc, tab: .builds, helpText: "Refresh builds")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            if asc.builds.isEmpty {
                if asc.isTabLoading(.builds) {
                    ASCTabLoadingPlaceholder(
                        title: "Loading Builds",
                        message: "Fetching TestFlight build metadata."
                    )
                } else {
                    ContentUnavailableView(
                        "No Builds",
                        systemImage: "hammer",
                        description: Text("No TestFlight builds found. Upload a build from Xcode.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                HStack(spacing: 0) {
                    // Build list
                    List(selection: $selectedBuildId) {
                        ForEach(asc.builds) { build in
                            buildRow(build)
                                .tag(build.id)
                        }
                    }
                    .listStyle(.inset)
                    .frame(width: 300)

                    Divider()

                    // Detail panel
                    if let bid = selectedBuildId,
                       let build = asc.builds.first(where: { $0.id == bid }) {
                        buildDetail(build)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView("Select a Build", systemImage: "hammer")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
    }

    private func buildRow(_ build: ASCBuild) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Version \(build.attributes.version)")
                    .font(.callout.weight(.medium))
                Spacer()
                stateBadge(build.attributes.processingState ?? "Unknown")
            }
            HStack {
                if let date = build.attributes.uploadedDate {
                    Text(ascShortDate(date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if build.attributes.expired == true {
                    Text("• Expired")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func buildDetail(_ build: ASCBuild) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Build \(build.attributes.version)")
                    .font(.title3.weight(.semibold))
                    .padding(.bottom, 16)

                InfoRow(label: "Build Number", value: build.attributes.version)
                Divider().padding(.leading, 150)
                InfoRow(label: "Processing State", value: build.attributes.processingState ?? "—")
                Divider().padding(.leading, 150)

                if let date = build.attributes.uploadedDate {
                    InfoRow(label: "Uploaded", value: ascLongDate(date))
                    Divider().padding(.leading, 150)
                }
                if let expiry = build.attributes.expirationDate {
                    InfoRow(label: "Expires", value: ascShortDate(expiry))
                    Divider().padding(.leading, 150)
                }
                if let minOS = build.attributes.minOsVersion {
                    InfoRow(label: "Min OS Version", value: "iOS \(minOS)")
                    Divider().padding(.leading, 150)
                }
                InfoRow(label: "Expired", value: build.attributes.expired == true ? "Yes" : "No")
                Divider().padding(.leading, 150)
                InfoRow(label: "Build ID", value: build.id)
            }
            .padding(24)
        }
    }

    private func stateBadge(_ state: String) -> some View {
        let color: Color = switch state {
        case "PROCESSING": .orange
        case "FAILED": .red
        case "INVALID": .red
        case "VALID": .green
        default: .secondary
        }
        return Text(state.capitalized)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func syncSelectedBuild() {
        if let selectedBuildId,
           asc.builds.contains(where: { $0.id == selectedBuildId }) {
            return
        }
        selectedBuildId = asc.builds.first?.id
    }
}

import SwiftUI

struct AppDetailsView: View {
    var appState: AppState

    private var asc: ASCManager { appState.ascManager }

    // Editable submission fields
    @State private var copyright: String = ""
    @State private var primaryCategory: String = ""
    @State private var contentRights: String = ""
    @State private var teamId: String = ""
    @FocusState private var focusedField: String?
    @State private var isSaving = false

    private static let categories: [(String, String)] = [
        ("GAMES", "Games"),
        ("UTILITIES", "Utilities"),
        ("PRODUCTIVITY", "Productivity"),
        ("SOCIAL_NETWORKING", "Social Networking"),
        ("PHOTO_AND_VIDEO", "Photo & Video"),
        ("MUSIC", "Music"),
        ("TRAVEL", "Travel"),
        ("SPORTS", "Sports"),
        ("HEALTH_AND_FITNESS", "Health & Fitness"),
        ("EDUCATION", "Education"),
        ("BUSINESS", "Business"),
        ("FINANCE", "Finance"),
        ("NEWS", "News"),
        ("FOOD_AND_DRINK", "Food & Drink"),
        ("LIFESTYLE", "Lifestyle"),
        ("SHOPPING", "Shopping"),
        ("ENTERTAINMENT", "Entertainment"),
        ("REFERENCE", "Reference"),
        ("MEDICAL", "Medical"),
        ("NAVIGATION", "Navigation"),
        ("WEATHER", "Weather"),
        ("DEVELOPER_TOOLS", "Developer Tools"),
    ]

    private static let contentRightsOptions: [(String, String)] = [
        ("DOES_NOT_USE_THIRD_PARTY_CONTENT", "Does Not Use Third-Party Content"),
        ("USES_THIRD_PARTY_CONTENT", "Uses Third-Party Content"),
    ]

    var body: some View {
        ASCCredentialGate(
            ascManager: asc,
            projectId: appState.activeProjectId ?? "",
            bundleId: appState.activeProject?.metadata.bundleIdentifier
        ) {
            ASCTabContent(asc: asc, tab: .appDetails) {
                detailsContent
            }
        }
        .task { await asc.fetchTabData(.appDetails) }
    }

    @ViewBuilder
    private var detailsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("App Identity")

                if let app = asc.app {
                    InfoRow(label: "App Name", value: app.name)
                    Divider().padding(.leading, 150)
                    InfoRow(label: "Bundle ID", value: app.bundleId)
                    Divider().padding(.leading, 150)
                    if let locale = app.primaryLocale {
                        InfoRow(label: "Primary Locale", value: locale)
                        Divider().padding(.leading, 150)
                    }
                    if let vendor = app.vendorNumber {
                        InfoRow(label: "Vendor Number", value: vendor)
                        Divider().padding(.leading, 150)
                    }
                    InfoRow(label: "App ID", value: app.id)
                }

                sectionHeader("Version Information")
                    .padding(.top, 20)

                if asc.appStoreVersions.isEmpty {
                    Text("No versions found")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(Array(asc.appStoreVersions.prefix(5).enumerated()), id: \.element.id) { idx, version in
                        HStack {
                            Text(version.attributes.versionString)
                                .font(.callout.weight(.medium))
                                .frame(width: 80, alignment: .leading)
                            Text(version.attributes.releaseType ?? "—")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(width: 150, alignment: .leading)
                            Text(version.attributes.appStoreState ?? "—")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if let date = version.attributes.createdDate {
                                Text(ascShortDate(date))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 8)
                        if idx < min(4, asc.appStoreVersions.count - 1) {
                            Divider()
                        }
                    }
                }

                sectionHeader("Submission Info")
                    .padding(.top, 20)

                VStack(alignment: .leading, spacing: 16) {
                    // Copyright
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Copyright")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("e.g. 2026 Acme Inc", text: $copyright)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: "copyright")
                    }

                    // Primary Category
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Primary Category")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $primaryCategory) {
                            Text("Select…").tag("")
                            ForEach(Self.categories, id: \.0) { id, label in
                                Text(label).tag(id)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: primaryCategory) { _, newValue in
                            guard !newValue.isEmpty else { return }
                            Task {
                                isSaving = true
                                await asc.updateAppInfoField("primaryCategory", value: newValue)
                                isSaving = false
                            }
                        }
                    }

                    // Content Rights
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Content Rights Declaration")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $contentRights) {
                            Text("Select…").tag("")
                            ForEach(Self.contentRightsOptions, id: \.0) { id, label in
                                Text(label).tag(id)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: contentRights) { _, newValue in
                            guard !newValue.isEmpty else { return }
                            Task {
                                isSaving = true
                                await asc.updateAppInfoField("contentRightsDeclaration", value: newValue)
                                isSaving = false
                            }
                        }
                    }

                    if isSaving {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Saving…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                sectionHeader("Project Settings")
                    .padding(.top, 20)

                if let project = appState.activeProject {
                    InfoRow(label: "Project Name", value: project.name)
                    Divider().padding(.leading, 150)
                    InfoRow(label: "Project Type", value: project.type.rawValue)
                    if let bid = project.metadata.bundleIdentifier {
                        Divider().padding(.leading, 150)
                        InfoRow(label: "Bundle ID (local)", value: bid)
                    }
                }

                sectionHeader("Build Signing")
                    .padding(.top, 20)

                VStack(alignment: .leading, spacing: 16) {
                    // Team ID
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Team ID")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("e.g. 4GS43493GL", text: $teamId)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: "teamId")
                            .fontDesign(.monospaced)
                    }

                    // Signing state (read-only)
                    if let project = appState.activeProject {
                        let signingState = loadSigningState(bundleId: project.metadata.bundleIdentifier ?? "")
                        if signingState.certificateId != nil || signingState.profileUUID != nil {
                            VStack(alignment: .leading, spacing: 8) {
                                if let certId = signingState.certificateId {
                                    HStack(spacing: 6) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                            .font(.callout)
                                        Text("Distribution Certificate")
                                            .font(.callout)
                                        Spacer()
                                        Text(certId)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .fontDesign(.monospaced)
                                            .lineLimit(1)
                                    }
                                }
                                if let uuid = signingState.profileUUID {
                                    HStack(spacing: 6) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                            .font(.callout)
                                        Text("Provisioning Profile")
                                            .font(.callout)
                                        Spacer()
                                        Text(uuid)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .fontDesign(.monospaced)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        } else {
                            Text("No signing configured. Run app_store_setup_signing or set a Team ID above.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if isSaving {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Saving…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(24)
        }
        .onAppear {
            populateFields()
            applyPendingValues()
        }
        .onChange(of: asc.appInfo?.id) { _, _ in populateFields() }
        .onChange(of: asc.pendingFormVersion) { _, _ in applyPendingValues() }
        .onChange(of: focusedField) { oldField, _ in
            if oldField == "copyright", !copyright.isEmpty {
                Task {
                    isSaving = true
                    await asc.updateAppInfoField("copyright", value: copyright)
                    isSaving = false
                }
            }
            if oldField == "teamId" {
                saveTeamId()
            }
        }
    }

    private func populateFields() {
        primaryCategory = asc.appInfo?.primaryCategoryId ?? ""
        contentRights = asc.app?.contentRightsDeclaration ?? ""
        // Copyright comes from the version, not appInfo — we don't have it in the model yet,
        // so initialize from pending if available

        // Load team ID from project metadata
        if let project = appState.activeProject {
            teamId = project.metadata.teamId ?? ""
        }
    }

    private func applyPendingValues() {
        guard let pending = asc.pendingFormValues["appDetails"] else { return }
        for (field, value) in pending {
            switch field {
            case "copyright": copyright = value
            case "primaryCategory": primaryCategory = value
            case "contentRightsDeclaration": contentRights = value
            default: break
            }
        }
    }

    private func saveTeamId() {
        let trimmed = teamId.trimmingCharacters(in: .whitespaces)
        guard let projectId = appState.activeProjectId else { return }
        let storage = ProjectStorage()
        guard var metadata = storage.readMetadata(projectId: projectId) else { return }
        metadata.teamId = trimmed.isEmpty ? nil : trimmed
        try? storage.writeMetadata(projectId: projectId, metadata: metadata)
    }

    private struct SigningStateSnapshot {
        var certificateId: String?
        var profileUUID: String?
    }

    private func loadSigningState(bundleId: String) -> SigningStateSnapshot {
        guard !bundleId.isEmpty else { return SigningStateSnapshot() }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(".blitz/signing/\(bundleId)/signing-state.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONDecoder().decode(BuildPipelineService.SigningState.self, from: data) else {
            return SigningStateSnapshot()
        }
        return SigningStateSnapshot(certificateId: json.certificateId, profileUUID: json.profileUUID)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.bottom, 6)
    }
}

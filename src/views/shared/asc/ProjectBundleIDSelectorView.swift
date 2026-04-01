import SwiftUI

struct ProjectBundleIDSelectorView: View {
    var appState: AppState
    var asc: ASCManager
    var tab: AppTab
    var platform: ProjectPlatform = .iOS
    var title: String = "Project Bundle ID"
    var subtitle: String? = nil
    var standalone: Bool = false

    @State private var discoveredBundleIds: [String] = []
    @State private var selectedBundleId = ""
    @State private var isSaving = false
    @State private var isResolvingCandidates = false
    @State private var isASCFilteredSelection = false
    @State private var error: String?
    @State private var showRegistrationFlow = false

    private var currentProject: Project? {
        appState.activeProject
    }

    private var currentBundleId: String? {
        normalized(appState.activeProject?.metadata.bundleIdentifier)
    }

    private var isImportedProject: Bool {
        guard let projectPath = currentProject?.path,
              let attrs = try? FileManager.default.attributesOfItem(atPath: projectPath),
              let fileType = attrs[.type] as? FileAttributeType else {
            return false
        }
        return fileType == .typeSymbolicLink
    }

    private var selectionOptions: [String] {
        if isASCFilteredSelection {
            return discoveredBundleIds
        }

        var options: [String] = []

        if let currentBundleId {
            options.append(currentBundleId)
        }

        options.append(contentsOf: discoveredBundleIds)

        var seen: Set<String> = []
        return options.filter { seen.insert($0).inserted }
    }

    private var resolvedSubtitle: String {
        if let subtitle {
            return subtitle
        }

        if asc.app == nil {
            if let currentBundleId {
                return "No App Store Connect app was found for \(currentBundleId). Select another discovered bundle ID or register a new one."
            }

            return "Choose which discovered bundle ID Blitz should use for this project before loading App Store Connect data."
        }

        return "Switch which bundle ID this project uses for App Store Connect. You can return here later if you need to point the project at a different target."
    }

    private var discoveryDescription: String {
        if isASCFilteredSelection {
            switch discoveredBundleIds.count {
            case 0:
                return "No discovered bundle IDs have matching App Store Connect apps."
            case 1:
                return "1 discovered bundle ID has a matching App Store Connect app."
            default:
                return "\(discoveredBundleIds.count) discovered bundle IDs have matching App Store Connect apps."
            }
        }

        switch discoveredBundleIds.count {
        case 0:
            return "No bundle IDs were discovered in this project."
        case 1:
            return "1 bundle ID was discovered in this project."
        default:
            return "\(discoveredBundleIds.count) bundle IDs were discovered in this project."
        }
    }

    private var primaryButtonTitle: String {
        asc.app == nil ? "Use Selected Bundle ID" : "Switch Bundle ID"
    }

    private var canSubmitSelection: Bool {
        normalized(selectedBundleId) != nil && !isSaving
    }

    private var discoveryTaskKey: String {
        [
            appState.activeProjectId ?? "",
            currentProject?.path ?? "",
            currentBundleId ?? "",
        ].joined(separator: "::")
    }

    var body: some View {
        Group {
            if currentProject == nil {
                ASCNoProjectSelectedView()
            } else if isResolvingCandidates {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Checking discovered bundle IDs in App Store Connect…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showRegistrationFlow {
                BundleIDSetupView(appState: appState, asc: asc, tab: tab, platform: platform)
            } else if standalone {
                ScrollView {
                    content
                        .padding(32)
                        .frame(maxWidth: 560, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .task(id: discoveryTaskKey) {
            await reloadDiscoveredBundleIds()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(standalone ? .title2.weight(.semibold) : .headline)
                Text(resolvedSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            if selectionOptions.isEmpty {
                Text("No saved or discovered bundle IDs are available yet. Register a new bundle ID to continue.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bundle ID")
                        .font(.callout.weight(.medium))

                    Picker("Bundle ID", selection: $selectedBundleId) {
                        Text("Select a bundle ID").tag("")
                        ForEach(selectionOptions, id: \.self) { bundleId in
                            Text(bundleId).tag(bundleId)
                        }
                    }
                    .pickerStyle(.menu)

                    Text(discoveryDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let currentBundleId,
               asc.app == nil {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Current project bundle ID: \(currentBundleId)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(primaryButtonTitle) {
                    Task { await applySelectedBundleId() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmitSelection)

                Button("Refresh Detected IDs") {
                    Task { await reloadDiscoveredBundleIds() }
                }
                .buttonStyle(.bordered)
                .disabled(isResolvingCandidates || isSaving)

                Spacer()

                Button("Register New Bundle ID") {
                    showRegistrationFlow = true
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(standalone ? 0 : 16)
        .background {
            if !standalone {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.background.secondary)
            }
        }
    }

    private func reloadDiscoveredBundleIds() async {
        guard let project = currentProject else {
            discoveredBundleIds = []
            selectedBundleId = ""
            isASCFilteredSelection = false
            return
        }

        let projectURL = URL(fileURLWithPath: project.path)
        let candidates = ProjectMetadataHydrator().discoverBundleIdentifiers(projectDirectory: projectURL)
        error = nil
        isASCFilteredSelection = false

        // Newly created local Blitz projects should go directly to bundle registration
        // when ASC app lookup fails, instead of showing a one-option selector.
        if standalone, asc.app == nil, !isImportedProject {
            discoveredBundleIds = candidates
            applyDefaultSelection(candidates)
            showRegistrationFlow = true
            return
        }

        // Fallback mode only: when app lookup failed and multiple targets were discovered,
        // keep only bundle IDs that already map to ASC apps before deciding the next UI.
        if standalone, asc.app == nil, candidates.count > 1 {
            showRegistrationFlow = false
            await resolveFallbackCandidates(candidates)
            return
        }

        showRegistrationFlow = false
        discoveredBundleIds = candidates
        applyDefaultSelection(candidates)
    }

    @MainActor
    private func applySelectedBundleId() async {
        guard let projectId = appState.activeProjectId else {
            error = "No active project is selected."
            return
        }

        guard let bundleId = normalized(selectedBundleId) else {
            error = "Select a bundle ID before continuing."
            return
        }

        isSaving = true
        error = nil

        do {
            let storage = ProjectStorage()
            guard var metadata = storage.readMetadata(projectId: projectId) else {
                throw ProjectOpenError.notABlitzProject
            }

            if normalized(metadata.bundleIdentifier) != bundleId {
                metadata.bundleIdentifier = bundleId
                try storage.writeMetadata(projectId: projectId, metadata: metadata)
            }

            await appState.projectManager.loadProjects()

            asc.prepareForProjectSwitch(to: projectId, bundleId: bundleId)
            await asc.loadCredentials(for: projectId, bundleId: bundleId)

            if asc.app != nil {
                await asc.ensureTabData(tab)
            }
        } catch {
            self.error = error.localizedDescription
        }

        isSaving = false
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func applyDefaultSelection(_ candidates: [String], restrictToCandidates: Bool = false) {
        if let currentBundleId,
           (!restrictToCandidates || candidates.contains(currentBundleId)) {
            selectedBundleId = currentBundleId
        } else if candidates.count == 1 {
            selectedBundleId = candidates[0]
        } else if restrictToCandidates {
            if !candidates.contains(selectedBundleId) {
                selectedBundleId = candidates.first ?? ""
            }
        } else if !candidates.contains(selectedBundleId) {
            selectedBundleId = ""
        }
    }

    @MainActor
    private func resolveFallbackCandidates(_ candidates: [String]) async {
        guard let service = asc.service else {
            discoveredBundleIds = candidates
            applyDefaultSelection(candidates)
            return
        }

        isResolvingCandidates = true
        defer { isResolvingCandidates = false }

        do {
            let candidatesWithApps = try await filterCandidatesWithApps(candidates, service: service)
            switch candidatesWithApps.count {
            case 0:
                discoveredBundleIds = []
                selectedBundleId = ""
                isASCFilteredSelection = true
                showRegistrationFlow = true
            case 1:
                discoveredBundleIds = candidatesWithApps
                isASCFilteredSelection = true
                selectedBundleId = candidatesWithApps[0]
                await applySelectedBundleId()
            default:
                discoveredBundleIds = candidatesWithApps
                isASCFilteredSelection = true
                applyDefaultSelection(candidatesWithApps, restrictToCandidates: true)
            }
        } catch {
            discoveredBundleIds = candidates
            applyDefaultSelection(candidates)
            isASCFilteredSelection = false
            self.error = "Could not verify discovered bundle IDs in App Store Connect: \(error.localizedDescription)"
        }
    }

    private func filterCandidatesWithApps(
        _ candidates: [String],
        service: AppStoreConnectService
    ) async throws -> [String] {
        var matched: [String] = []
        for candidate in candidates {
            do {
                _ = try await service.fetchApp(bundleId: candidate)
                matched.append(candidate)
            } catch let error as ASCError {
                if case .notFound = error {
                    continue
                }
                throw error
            }
        }
        return matched
    }
}

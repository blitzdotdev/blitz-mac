import SwiftUI

struct SubmitPreviewSheet: View {
    var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private var asc: ASCManager { appState.ascManager }

    @State private var selectedBuildId: String = ""
    @State private var appIcon: NSImage?

    private var validBuilds: [ASCBuild] {
        asc.builds.filter { $0.attributes.processingState == "VALID" && $0.attributes.expired != true }
    }

    /// States where the version is locked and cannot be (re-)submitted.
    private static let nonSubmittableStates: Set<String> = [
        "WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_DEVELOPER_RELEASE", "READY_FOR_SALE"
    ]

    private var pendingVersion: ASCAppStoreVersion? {
        asc.appStoreVersions.first {
            let s = $0.attributes.appStoreState ?? ""
            return s != "READY_FOR_SALE" && s != "REMOVED_FROM_SALE"
                && s != "DEVELOPER_REMOVED_FROM_SALE" && !s.isEmpty
        }
    }

    private var versionState: String {
        pendingVersion?.attributes.appStoreState ?? ""
    }

    private var isSubmittable: Bool {
        !Self.nonSubmittableStates.contains(versionState)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(isSubmittable ? "Submit for Review" : "Submission Status")
                .font(.title2.weight(.semibold))

            // App header: icon + info
            HStack(alignment: .top, spacing: 20) {
                // App icon
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                } else {
                    RoundedRectangle(cornerRadius: 22)
                        .fill(.blue.gradient)
                        .frame(width: 100, height: 100)
                        .overlay(
                            Image(systemName: "app.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(.white)
                        )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(asc.app?.name ?? "App")
                        .font(.title3.weight(.semibold))
                    if let version = pendingVersion ?? asc.appStoreVersions.first {
                        Text("Version \(version.attributes.versionString)")
                            .foregroundStyle(.secondary)
                    }
                    Text(asc.app?.bundleId ?? "")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)

                    if isSubmittable {
                        buildSelector
                    } else {
                        versionStatusBadge
                    }
                }
            }

            Divider()

            if isSubmittable {
                submittableContent
            } else {
                nonSubmittableContent
            }

            // Footer buttons
            HStack {
                Button(isSubmittable ? "Cancel" : "Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if isSubmittable {
                    Button("Submit for Review") {
                        Task {
                            let buildId = selectedBuildId.isEmpty ? nil : selectedBuildId
                            await asc.submitForReview(attachBuildId: buildId)
                            if asc.submissionError == nil {
                                dismiss()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(asc.isSubmitting || !asc.submissionReadiness.isComplete || selectedBuildId.isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .task {
            if asc.builds.isEmpty {
                await asc.refreshTabData(.builds)
            }
            if selectedBuildId.isEmpty, let latest = validBuilds.first {
                selectedBuildId = latest.id
            }
            appIcon = loadAppIcon()
        }
    }

    // MARK: - Build Selector

    @ViewBuilder
    private var buildSelector: some View {
        if validBuilds.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                Text("No valid builds available")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            .padding(.top, 4)
        } else {
            Picker(selection: $selectedBuildId) {
                Text("Select a build\u{2026}").tag("")
                ForEach(validBuilds) { build in
                    Text("Build \(build.attributes.version)")
                        .tag(build.id)
                }
            } label: {
                Text("Build")
                    .font(.callout.weight(.medium))
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 200)
            .padding(.top, 4)
        }
    }

    // MARK: - Version Status Badge (non-submittable)

    private var versionStatusBadge: some View {
        let (label, color) = stateDisplay(versionState)
        return HStack(spacing: 6) {
            Image(systemName: stateIcon(versionState))
                .foregroundStyle(color)
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(color)
        }
        .padding(.top, 4)
    }

    // MARK: - Submittable Content

    @ViewBuilder
    private var submittableContent: some View {
        let readiness = asc.submissionReadiness
        if !readiness.missingRequired.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Missing Required Fields")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.red)
                ForEach(readiness.missingRequired) { field in
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                        Text(field.label)
                            .font(.callout)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        if asc.isSubmitting {
            HStack(spacing: 12) {
                ProgressView()
                Text("Submitting for review\u{2026}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }

        if let error = asc.submissionError {
            Text(error)
                .font(.callout)
                .foregroundStyle(.red)
                .padding(8)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Non-Submittable Content

    private var nonSubmittableContent: some View {
        let (label, color) = stateDisplay(versionState)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: stateIcon(versionState))
                    .font(.title3)
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Version is \(label)")
                        .font(.callout.weight(.medium))
                    Text("You cannot modify the build or re-submit while in this state.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Show submission details when rejected
            if versionState == "REJECTED" {
                if !asc.latestSubmissionItems.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(asc.latestSubmissionItems) { item in
                            HStack(spacing: 6) {
                                Image(systemName: item.attributes.state == "REJECTED" ? "xmark.circle.fill" : "checkmark.circle.fill")
                                    .foregroundStyle(item.attributes.state == "REJECTED" ? .red : .green)
                                    .font(.caption)
                                Text(item.attributes.state?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Unknown")
                                    .font(.callout)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    // MARK: - Helpers

    private func stateDisplay(_ state: String) -> (String, Color) {
        switch state {
        case "WAITING_FOR_REVIEW": return ("Waiting for Review", .blue)
        case "IN_REVIEW": return ("In Review", .blue)
        case "PENDING_DEVELOPER_RELEASE": return ("Pending Release", .green)
        case "READY_FOR_SALE": return ("Ready for Sale", .green)
        case "PREPARE_FOR_SUBMISSION": return ("Preparing", .orange)
        case "INVALID_BINARY": return ("Submission Error", .red)
        case "REJECTED": return ("Rejected", .red)
        case "DEVELOPER_REJECTED": return ("Developer Rejected", .orange)
        default: return (state.replacingOccurrences(of: "_", with: " ").capitalized, .secondary)
        }
    }

    private func stateIcon(_ state: String) -> String {
        switch state {
        case "WAITING_FOR_REVIEW": return "clock.badge.checkmark"
        case "IN_REVIEW": return "eye.fill"
        case "PENDING_DEVELOPER_RELEASE": return "checkmark.seal.fill"
        case "READY_FOR_SALE": return "checkmark.circle.fill"
        case "INVALID_BINARY", "REJECTED", "DEVELOPER_REJECTED": return "xmark.circle.fill"
        default: return "info.circle.fill"
        }
    }

    // MARK: - App Icon Loading

    private func loadAppIcon() -> NSImage? {
        guard let projectId = appState.activeProjectId else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        let blitzPath = "\(home)/.blitz/projects/\(projectId)/assets/AppIcon/icon_1024.png"
        if let image = NSImage(contentsOfFile: blitzPath) {
            return image
        }

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
                    let iconPath = "\(iconDir)/\(filename)"
                    if let image = NSImage(contentsOfFile: iconPath) {
                        return image
                    }
                }
            }
        }
        return nil
    }
}

import SwiftUI

struct CreateUpdateSheet: View {
    var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private var asc: ASCManager { appState.ascManager }

    @State private var versionString = ""
    @State private var copyFromVersionId = ""
    @State private var copyMetadata = true
    @State private var copyReviewDetail = true
    @State private var attachBuild = true
    @State private var selectedBuildId = ""

    private var validBuilds: [ASCBuild] {
        asc.builds.filter { $0.attributes.processingState == "VALID" && $0.attributes.expired != true }
    }

    private var sourceVersions: [ASCAppStoreVersion] {
        asc.appStoreVersions
    }

    private var blockerMessage: String? {
        asc.newVersionCreationBlockerMessage(desiredVersionString: versionString)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Create Update")
                .font(.title2.weight(.semibold))

            Text("Create the next App Store version for this live app, optionally copying metadata and review contact details from an existing version.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Version")
                    .font(.callout.weight(.medium))
                TextField("e.g. 1.2.4", text: $versionString)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Copy store listing metadata from an existing version", isOn: $copyMetadata)
                Toggle("Copy review contact details", isOn: $copyReviewDetail)

                Picker("Copy From", selection: $copyFromVersionId) {
                    Text("None").tag("")
                    ForEach(sourceVersions) { version in
                        Text("Version \(version.attributes.versionString)")
                            .tag(version.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!copyMetadata && !copyReviewDetail)
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Attach a build now", isOn: $attachBuild)

                Picker("Build", selection: $selectedBuildId) {
                    Text("None").tag("")
                    ForEach(validBuilds) { build in
                        Text("Build \(build.attributes.version)")
                            .tag(build.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!attachBuild)

                if attachBuild && validBuilds.isEmpty {
                    Text("No valid builds are available yet. You can still create the update and attach a build later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let blockerMessage {
                Text(blockerMessage)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if let error = asc.versionCreationError, !error.isEmpty {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create Update") {
                    Task {
                        let resolvedSourceVersionId = (copyMetadata || copyReviewDetail) && !copyFromVersionId.isEmpty
                            ? copyFromVersionId
                            : nil
                        let resolvedBuildId = attachBuild && !selectedBuildId.isEmpty ? selectedBuildId : nil
                        await asc.createUpdateVersion(
                            versionString: versionString,
                            platform: appState.activeProject?.platform ?? .iOS,
                            copyFromVersionId: resolvedSourceVersionId,
                            copyMetadata: copyMetadata,
                            copyReviewDetail: copyReviewDetail,
                            attachBuildId: resolvedBuildId
                        )
                        if asc.versionCreationError == nil {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    asc.isCreatingVersion
                        || blockerMessage != nil
                        || versionString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .task {
            if asc.builds.isEmpty {
                await asc.refreshTabData(.builds)
            }
            if versionString.isEmpty {
                versionString = suggestedNextVersion(from: asc.liveVersion?.attributes.versionString)
            }
            if copyFromVersionId.isEmpty {
                copyFromVersionId = asc.liveVersion?.id ?? asc.appStoreVersions.first?.id ?? ""
            }
            if selectedBuildId.isEmpty {
                selectedBuildId = validBuilds.first?.id ?? ""
            }
        }
    }

    private func suggestedNextVersion(from source: String?) -> String {
        guard let source = source?.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty else {
            return ""
        }

        var components = source.split(separator: ".").map(String.init)
        guard let last = components.last, let lastValue = Int(last) else {
            return ""
        }
        components[components.count - 1] = String(lastValue + 1)
        return components.joined(separator: ".")
    }
}

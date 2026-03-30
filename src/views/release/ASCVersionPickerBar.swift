import SwiftUI

struct ASCVersionPickerBar<Content: View>: View {
    var asc: ASCManager
    var selection: Binding<String>
    var onCreateUpdate: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) {
            if !asc.appStoreVersions.isEmpty {
                Picker("Version", selection: selection) {
                    ForEach(asc.appStoreVersions) { version in
                        Text("Version \(version.attributes.versionString)")
                            .tag(version.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 190)
            }

            if let selectedVersion = asc.selectedVersion {
                stateBadge(selectedVersion.attributes.appStoreState ?? "")
                Text("Target \(selectedVersion.attributes.versionString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            content

            Spacer()

            if asc.canCreateVersion, let onCreateUpdate {
                Button("Create New Update") {
                    onCreateUpdate()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func stateBadge(_ state: String) -> some View {
        let normalizedState = ASCReleaseStatus.normalize(state)
        let color: Color
        if ASCReleaseStatus.isLive(normalizedState) {
            color = .green
        } else if ASCReleaseStatus.isEditable(normalizedState) {
            color = .orange
        } else if ASCReleaseStatus.pendingReviewStates.contains(normalizedState) {
            color = .blue
        } else if ASCReleaseStatus.rejectedStates.contains(normalizedState) {
            color = .red
        } else {
            color = .secondary
        }

        return Text(normalizedState.replacingOccurrences(of: "_", with: " ").capitalized)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

extension ASCVersionPickerBar where Content == EmptyView {
    init(asc: ASCManager, selection: Binding<String>, onCreateUpdate: (() -> Void)? = nil) {
        self.asc = asc
        self.selection = selection
        self.onCreateUpdate = onCreateUpdate
        self.content = EmptyView()
    }
}

import SwiftUI

struct GroupsView: View {
    var appState: AppState

    private var asc: ASCManager { appState.ascManager }

    var body: some View {
        ASCCredentialGate(
            ascManager: asc,
            projectId: appState.activeProjectId ?? "",
            bundleId: appState.activeProject?.metadata.bundleIdentifier
        ) {
            ASCTabContent(asc: asc, tab: .groups) {
                groupsContent
            }
        }
        .task { await asc.fetchTabData(.groups) }
    }

    @ViewBuilder
    private var groupsContent: some View {
        if asc.betaGroups.isEmpty {
            ContentUnavailableView(
                "No Beta Groups",
                systemImage: "person.3",
                description: Text("No beta testing groups found for this app.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 12) {
                    let internal_ = asc.betaGroups.filter { $0.attributes.isInternalGroup == true }
                    let external = asc.betaGroups.filter { $0.attributes.isInternalGroup != true }

                    if !internal_.isEmpty {
                        groupSection("Internal Groups", groups: internal_, color: .blue)
                    }
                    if !external.isEmpty {
                        groupSection("External Groups", groups: external, color: .green)
                    }
                }
                .padding(20)
            }
        }
    }

    private func groupSection(_ title: String, groups: [ASCBetaGroup], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { idx, group in
                    groupRow(group, color: color)
                    if idx < groups.count - 1 {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func groupRow(_ group: ASCBetaGroup, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: group.attributes.isInternalGroup == true ? "person.fill.badge.plus" : "person.2.fill")
                .foregroundStyle(color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(group.attributes.name)
                    .font(.callout.weight(.medium))

                HStack(spacing: 8) {
                    if group.attributes.isInternalGroup == true {
                        badge("Internal", color: .blue)
                    } else {
                        badge("External", color: .green)
                    }
                    if group.attributes.hasAccessToAllBuilds == true {
                        badge("All Builds", color: .secondary)
                    }
                    if group.attributes.publicLinkEnabled == true {
                        badge("Public Link", color: .purple)
                    }
                    if group.attributes.feedbackEnabled == true {
                        badge("Feedback", color: .orange)
                    }
                }
            }

            Spacer()

            if let appId = asc.app?.id {
                Link(destination: URL(string: "https://appstoreconnect.apple.com/apps/\(appId)/testflight/groups")!) {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

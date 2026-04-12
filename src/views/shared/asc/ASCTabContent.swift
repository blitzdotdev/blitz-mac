import SwiftUI

/// Wraps a tab's content with loading, error, and empty-app states.
struct ASCTabContent<Content: View>: View {
    var appState: AppState
    var asc: ASCManager
    var tab: AppTab
    var platform: ProjectPlatform = .iOS
    /// When true, tabs can render with only an ASC app loaded (no local project required).
    /// The synthesized App > Overview dashboard uses this so users can manage their
    /// ASC-only apps without first linking a local folder.
    var allowWithoutLocalProject: Bool = false
    @ViewBuilder var content: () -> Content

    private var isLoading: Bool {
        asc.isTabLoading(tab)
    }

    private var shouldRenderContentWhileLoading: Bool {
        asc.credentials != nil && asc.app != nil
    }

    private var hasSelectedProject: Bool {
        appState.activeProject != nil
    }

    private var gateIsOpen: Bool {
        hasSelectedProject || (allowWithoutLocalProject && asc.app != nil)
    }

    var body: some View {
        if !gateIsOpen {
            ASCNoProjectSelectedView()
        } else if isLoading && !shouldRenderContentWhileLoading {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading\u{2026}")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if asc.app == nil && asc.credentials != nil && !isLoading {
            ProjectBundleIDSelectorView(
                appState: appState,
                asc: asc,
                tab: tab,
                platform: platform,
                title: "Select Project Bundle ID",
                standalone: true
            )
        } else if let error = asc.tabError[tab], !asc.hasLoadedTabData(tab) {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                Button("Retry") {
                    Task { await asc.refreshTabData(tab) }
                }
                .buttonStyle(.bordered)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content()
                .overlay(alignment: .topTrailing) {
                    if isLoading && shouldRenderContentWhileLoading {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(.background.secondary, in: Capsule())
                            .padding(12)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let error = asc.tabError[tab], asc.hasLoadedTabData(tab) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Button("Retry") {
                                Task { await asc.refreshTabData(tab) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                        .padding(12)
                    }
                }
        }
    }
}

struct ASCNoProjectSelectedView: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("Select a project first.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

struct ASCTabLoadingPlaceholder: View {
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(title)
                .font(.callout.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

struct ASCTabRefreshButton: View {
    var asc: ASCManager
    var tab: AppTab
    var helpText: String = "Refresh this tab"

    private var isRefreshing: Bool {
        asc.isLoadingTab[tab] == true
    }

    var body: some View {
        Button {
            Task { await asc.refreshTabData(tab) }
        } label: {
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(.borderless)
        .disabled(isRefreshing)
        .help(helpText)
    }
}

/// Reusable info row for detail views.
struct InfoRow: View {
    var label: String
    var value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

/// Formats an ISO 8601 date string for display.
func ascShortDate(_ iso: String) -> String {
    let f1 = ISO8601DateFormatter()
    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let f2 = ISO8601DateFormatter()
    if let d = f1.date(from: iso) ?? f2.date(from: iso) {
        return d.formatted(date: .abbreviated, time: .omitted)
    }
    return iso
}

/// Formats an ISO 8601 date string with time.
func ascLongDate(_ iso: String) -> String {
    let f1 = ISO8601DateFormatter()
    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let f2 = ISO8601DateFormatter()
    if let d = f1.date(from: iso) ?? f2.date(from: iso) {
        return d.formatted(date: .abbreviated, time: .shortened)
    }
    return iso
}

/// Converts HTML to plain text using NSAttributedString, with regex fallback.
func htmlToPlainText(_ html: String) -> String {
    if let data = html.data(using: .utf8),
       let attributed = try? NSAttributedString(
           data: data,
           options: [
               .documentType: NSAttributedString.DocumentType.html,
               .characterEncoding: String.Encoding.utf8.rawValue,
           ],
           documentAttributes: nil
       ) {
        return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    // Regex fallback: strip tags
    return html
        .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

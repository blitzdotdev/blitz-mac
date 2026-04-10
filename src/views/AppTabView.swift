import SwiftUI

struct AppTabView: View {
    @Bindable var appState: AppState

    /// Minimum width needed to keep every App sub-tab button on a single line.
    static let minimumSingleLineWidth: CGFloat = {
        let textFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        let symbolAllowance: CGFloat = 14
        let buttonInnerSpacing: CGFloat = 4
        let buttonHorizontalPadding: CGFloat = 20
        let interButtonSpacing: CGFloat = 2 * CGFloat(max(AppSubTab.visibleCases.count - 1, 0))
        let navbarHorizontalPadding: CGFloat = 32
        let safetyMargin: CGFloat = 24

        let totalButtonWidth = AppSubTab.visibleCases.reduce(CGFloat.zero) { partial, tab in
            let textWidth = ceil((tab.label as NSString).size(withAttributes: [.font: textFont]).width)
            return partial + textWidth + symbolAllowance + buttonInnerSpacing + buttonHorizontalPadding
        }

        return totalButtonWidth + interButtonSpacing + navbarHorizontalPadding + safetyMargin
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Top navbar
            topNavbar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)

            Divider()

            // Sub-tab content
            subTabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Top Navbar

    private var topNavbar: some View {
        HStack(spacing: 2) {
            ForEach(AppSubTab.visibleCases) { tab in
                Button {
                    appState.activeAppSubTab = tab
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 11))
                        Text(tab.label)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        appState.activeAppSubTab == tab
                            ? Color.accentColor.opacity(0.12)
                            : Color.clear
                    )
                    .foregroundStyle(
                        appState.activeAppSubTab == tab
                            ? Color.accentColor
                            : Color.secondary
                    )
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
    }

    // MARK: - Sub-tab Content

    @ViewBuilder
    private var subTabContent: some View {
        switch appState.activeAppSubTab {
        case .overview:
            ASCOverview(appState: appState)
        case .simulator:
            SimulatorView(appState: appState)
        case .tests:
            TestsView(appState: appState)
        case .icon:
            AssetsView(appState: appState)
        }
    }
}

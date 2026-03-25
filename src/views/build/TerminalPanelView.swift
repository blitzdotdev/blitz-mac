import SwiftUI

struct TerminalPanelView: View {
    @Bindable var appState: AppState

    private var manager: TerminalManager { appState.terminalManager }
    private var isRight: Bool { appState.settingsStore.terminalPosition == "right" }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            terminalContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 8) {
            sessionTabStrip
            tabBarControls
        }
        .padding(.leading, 8)
        .padding(.vertical, 2)
        .background(.bar)
    }

    private var sessionTabStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(manager.sessions) { session in
                        sessionTab(session)
                            .id(session.id)
                    }
                }
                .padding(.trailing, 4)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
                scrollToActiveSession(using: proxy, animated: false)
            }
            .onChange(of: manager.activeSessionId) { _, _ in
                scrollToActiveSession(using: proxy)
            }
            .onChange(of: manager.sessions.map(\.id)) { _, _ in
                scrollToActiveSession(using: proxy)
            }
        }
    }

    private var tabBarControls: some View {
        HStack(spacing: 0) {
            Button {
                manager.createSession(projectPath: appState.activeProject?.path)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("New terminal")

            Button {
                let settings = appState.settingsStore
                settings.terminalPosition = isRight ? "bottom" : "right"
                settings.save()
            } label: {
                Image(systemName: isRight ? "rectangle.bottomhalf.filled" : "rectangle.righthalf.filled")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(isRight ? "Move to bottom" : "Move to right")

            Button {
                appState.showTerminal = false
            } label: {
                Image(systemName: isRight ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Hide terminal panel")
            .padding(.trailing, 8)
        }
    }

    private func sessionTab(_ session: TerminalSession) -> some View {
        let isActive = session.id == manager.activeSessionId

        return HStack(spacing: 4) {
            Image(systemName: session.isTerminated ? "terminal" : "terminal.fill")
                .font(.system(size: 10))

            Text(session.title)
                .font(.system(size: 11, weight: isActive ? .medium : .regular))
                .lineLimit(1)

            // Close button
            Button {
                manager.closeSession(session.id)
                if manager.sessions.isEmpty {
                    appState.showTerminal = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .opacity(isActive ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isActive ? Color.primary.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture {
            manager.activeSessionId = session.id
        }
    }

    private func scrollToActiveSession(using proxy: ScrollViewProxy, animated: Bool = true) {
        guard let activeSessionId = manager.activeSessionId else { return }

        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(activeSessionId, anchor: .trailing)
                }
            } else {
                proxy.scrollTo(activeSessionId, anchor: .trailing)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var terminalContent: some View {
        if manager.sessions.isEmpty {
            VStack(spacing: 8) {
                Text("No terminal sessions")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("New Terminal") {
                    manager.createSession(projectPath: appState.activeProject?.path)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack {
                // Keep each session's host NSView alive so switching tabs does not require
                // SwiftUI to reparent a single LocalProcessTerminalView between containers.
                ForEach(manager.sessions) { session in
                    let isActive = session.id == manager.activeSessionId

                    TerminalSessionView(session: session, isActive: isActive)
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                        .zIndex(isActive ? 1 : 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

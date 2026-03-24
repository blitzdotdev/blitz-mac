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
        HStack(spacing: 0) {
            // Session tabs
            ForEach(manager.sessions) { session in
                sessionTab(session)
            }

            // New tab button
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

            Spacer()

            // Position toggle
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

            // Hide panel button
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
        .padding(.leading, 8)
        .padding(.vertical, 2)
        .background(.bar)
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

    // MARK: - Content

    @ViewBuilder
    private var terminalContent: some View {
        if let session = manager.activeSession {
            TerminalSessionView(session: session)
        } else {
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
        }
    }
}

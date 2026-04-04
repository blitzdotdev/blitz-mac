import SwiftUI

/// Hosts a `TerminalSession`'s terminal host view inside a container NSView.
/// The terminal view is owned by `TerminalSession` (not by SwiftUI), so it persists
/// across show/hide cycles and tab switches.
struct TerminalSessionView: NSViewRepresentable {
    let session: TerminalSession
    let isActive: Bool

    final class Coordinator {
        var lastActive = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        container.wantsLayer = true
        embed(session.terminalView, in: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let termView = session.terminalView
        // Re-embed only if the session's view isn't already in this container
        if termView.superview !== nsView {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            embed(termView, in: nsView)
        }

        guard isActive else {
            context.coordinator.lastActive = false
            return
        }

        termView.needsLayout = true
        termView.needsDisplay = true
        termView.displayIfNeeded()

        if !context.coordinator.lastActive, nsView.window?.firstResponder !== termView {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(termView)
            }
        }

        context.coordinator.lastActive = true
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        // Do NOT remove the terminal view here. It is managed by TerminalSession
        // and will be re-embedded by makeNSView when the view hierarchy is rebuilt
        // (e.g. switching split position). Removing it here causes the terminal's
        // rendering context to be lost, resulting in a blank view.
    }

    private func embed(_ termView: BlitzTerminalView, in container: NSView) {
        termView.removeFromSuperview()
        termView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(termView)
        NSLayoutConstraint.activate([
            termView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            termView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            termView.topAnchor.constraint(equalTo: container.topAnchor),
            termView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // Force a full redraw after re-embedding to restore rendering state
        termView.needsLayout = true
        termView.needsDisplay = true
    }
}

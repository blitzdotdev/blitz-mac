import SwiftUI
import SwiftTerm

/// Hosts a `TerminalSession`'s `LocalProcessTerminalView` inside a container NSView.
/// The terminal view is owned by `TerminalSession` (not by SwiftUI), so it persists
/// across show/hide cycles and tab switches.
struct TerminalSessionView: NSViewRepresentable {
    let session: TerminalSession

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
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        // Detach terminal view from container — the view itself lives on in TerminalSession
        nsView.subviews.forEach { $0.removeFromSuperview() }
    }

    private func embed(_ termView: LocalProcessTerminalView, in container: NSView) {
        termView.removeFromSuperview()
        termView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(termView)
        NSLayoutConstraint.activate([
            termView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            termView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            termView.topAnchor.constraint(equalTo: container.topAnchor),
            termView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

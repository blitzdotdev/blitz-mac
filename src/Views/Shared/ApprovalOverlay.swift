import SwiftUI

/// Modifier that shows a native macOS alert when an MCP tool requires user approval
struct ApprovalAlertModifier: ViewModifier {
    @Bindable var appState: AppState

    func body(content: Content) -> some View {
        content
            .alert(
                "AI Tool Request",
                isPresented: $appState.showApprovalAlert,
                presenting: appState.pendingApproval
            ) { request in
                Button("Deny", role: .cancel) {
                    appState.toolExecutor?.resolveApproval(id: request.id, approved: false)
                }
                Button("Approve") {
                    appState.toolExecutor?.resolveApproval(id: request.id, approved: true)
                }
            } message: { request in
                Text(request.description)
            }
    }
}

extension View {
    func approvalAlert(appState: AppState) -> some View {
        modifier(ApprovalAlertModifier(appState: appState))
    }
}

import SwiftUI

struct TestsView: View {
    @Bindable var appState: AppState

    private var iphoneMCPConfigured: Bool {
        guard let projectId = appState.activeProjectId else { return false }
        let mcpFile = ProjectStorage().baseDirectory
            .appendingPathComponent(projectId)
            .appendingPathComponent(".mcp.json")
        guard let data = try? Data(contentsOf: mcpFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any] else { return false }
        return servers["blitz-iphone"] != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                statusBadge
                ExampleCard(
                    title: "Add and Test a Feature",
                    icon: "person.badge.plus",
                    prompt: "Add user signup and login, then test the full flow on the simulator.",
                    preview: "Agent builds the feature, then walks through the entire UX flow on the simulator — tapping, typing, and verifying each screen.",
                    detail: detailSignup
                )
                ExampleCard(
                    title: "Take App Store Screenshots",
                    icon: "camera.viewfinder",
                    prompt: "Take 10 App Store screenshots in diverse UI states and upload them.",
                    preview: "Agent navigates the app into different states, captures screenshots, and uploads them to App Store Connect.",
                    detail: detailScreenshots
                )
                ExampleCard(
                    title: "Set Up and Test Subscriptions",
                    icon: "creditcard",
                    prompt: "Create a subscription, add a paywall, and test the purchase flow.",
                    preview: "Agent creates a subscription in ASC, adds a paywall to your codebase, and tests the purchase flow on a device.",
                    detail: detailSubscriptions
                )
            }
            .padding(32)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Automate Testing with AI Agents", systemImage: "sparkles")
                .font(.title2.weight(.semibold))

            Text("In a Blitz project directory, you can ask agents to use iPhones to test features and find bugs. Using Blitz's **iPhone-MCP**, your agent can tap, swipe, and type in both simulated and physical iPhone devices.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Status

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(iphoneMCPConfigured ? .green : .orange)
                .frame(width: 8, height: 8)
            Text(iphoneMCPConfigured
                 ? "iPhone-MCP configured in this project"
                 : "iPhone-MCP not found — open a project to get started")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Details

    private let detailSignup = """
    The agent generates the screens, hooks them up to your backend, then uses **iPhone-MCP** to walk through the flow:

    1. Launch the app and navigate to the signup screen
    2. Type a test email and password using `device_action`
    3. Tap "Sign Up" and verify the home screen loads
    4. Tap "Sign Out" and confirm it returns to login
    5. Sign back in with the same credentials
    6. Use `describe_screen` to verify the user is logged in

    If any step fails, the agent sees the actual screen and can debug immediately.
    """

    private let detailScreenshots = """
    The agent uses **iPhone-MCP** to put the app in exactly the right state before each capture:

    1. Navigate to each screen and configure the UI — scroll, tap into views, fill in data
    2. Call `get_screenshot` to capture each state at full resolution
    3. Use `screenshots_switch_localization` → `screenshots_put_track_slot` / `screenshots_remove_track_slot` / `screenshots_reorder_track` → `screenshots_save` to upload to App Store Connect

    You get pixel-perfect, context-rich screenshots without touching the simulator.
    """

    private let detailSubscriptions = """
    The agent handles the full lifecycle — from App Store Connect to on-device testing:

    1. Call `asc_create_subscription` to create a subscription group and pricing plan
    2. Add a paywall screen in your codebase triggered by the appropriate user action
    3. Build and deploy to a **physical device** with a sandbox Apple ID
    4. Use **iPhone-MCP** to navigate through the app until the paywall appears
    5. Tap "Subscribe" to trigger the sandbox Apple Pay flow
    6. Confirm the premium content unlocks after purchase

    **Note:** Create a Sandbox Apple Account in App Store Connect → Users and Access → Sandbox, and sign into it on the test device. The agent handles everything else.
    """
}

// MARK: - Example Card

private struct ExampleCard: View {
    let title: String
    let icon: String
    let prompt: String
    let preview: String
    let detail: String

    @State private var expanded = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.title3.weight(.medium))

            // Prompt block
            HStack(alignment: .top, spacing: 8) {
                Text(prompt)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .help("Copy prompt")
            }

            // Preview text
            Text(preview)
                .font(.body)
                .foregroundStyle(.secondary)

            // Expand/collapse
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(expanded ? "Hide details" : "How it works")
                        .font(.callout.weight(.medium))
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)

            // Detail section — uses disclosure group pattern with clipping
            if expanded {
                Text(LocalizedStringKey(detail))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .clipped()
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
    }
}

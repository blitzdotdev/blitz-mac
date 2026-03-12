import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsService
    var appState: AppState
    var mcpServer: MCPServerService?

    private let gateableCategories: [(ApprovalRequest.ToolCategory, String)] = [
        (.ascFormMutation, "ASC form editing"),
        (.ascScreenshotMutation, "ASC screenshot upload"),
        (.ascSubmitMutation, "ASC submit for review"),
        (.projectMutation, "Project mutations"),
        (.settingsMutation, "Settings mutations"),
        (.simulatorControl, "Simulator control"),
    ]

    var body: some View {
        Form {
            Section("Simulator") {
                Picker("Frame Rate", selection: $settings.simulatorFPS) {
                    Text("30 FPS").tag(30)
                    Text("60 FPS").tag(60)
                }

                Toggle("Show Cursor Overlay", isOn: $settings.showCursor)

                if settings.showCursor {
                    HStack {
                        Text("Cursor Size")
                        Slider(value: $settings.cursorSize, in: 10...40, step: 2)
                        Text("\(Int(settings.cursorSize))px")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }

            Section("Permissions") {
                Toggle("Auto-navigate to tab on tool call", isOn: $settings.autoNavEnabled)
                    .onChange(of: settings.autoNavEnabled) { _, _ in settings.save() }

                Divider()

                Toggle("Approve all", isOn: Binding(
                    get: {
                        gateableCategories.allSatisfy { settings.permissionToggles[$0.0.rawValue] ?? false }
                    },
                    set: { newValue in
                        for (category, _) in gateableCategories {
                            settings.permissionToggles[category.rawValue] = newValue
                        }
                        settings.save()
                    }
                ))
                .fontWeight(.medium)

                ForEach(gateableCategories, id: \.0.rawValue) { category, label in
                    Toggle(label, isOn: Binding(
                        get: { settings.permissionToggles[category.rawValue] ?? false },
                        set: { newValue in
                            settings.permissionToggles[category.rawValue] = newValue
                            settings.save()
                        }
                    ))
                }
            }

            MCPSetupSection(mcpServer: mcpServer)

            Section("About") {
                HStack {
                    Text("Blitz")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 500)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

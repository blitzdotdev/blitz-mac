import SwiftUI
import UniformTypeIdentifiers

struct ASCCredentialForm: View {
    var appState: AppState
    var ascManager: ASCManager
    var projectId: String
    var bundleId: String?

    @State private var issuerId = ""
    @State private var keyId = ""
    @State private var privateKey = ""
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showFilePicker = false
    @State private var showInstructions = false
    @State private var privateKeyFileName: String?

    private var isValid: Bool {
        !issuerId.trimmingCharacters(in: .whitespaces).isEmpty &&
        !keyId.trimmingCharacters(in: .whitespaces).isEmpty &&
        !privateKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.shield")
                            .font(.title2)
                            .foregroundStyle(.blue)
                        Text("Connect to App Store Connect")
                            .font(.title2.weight(.semibold))
                    }
                    Text("Enter your API credentials to access App Store data.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Step-by-step instructions for first-time setup
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showInstructions.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .rotationEffect(.degrees(showInstructions ? 90 : 0))
                                Text("How to generate your API key")
                                    .font(.callout.weight(.medium))
                            }
                            .foregroundStyle(.blue)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if showInstructions {
                            VStack(alignment: .leading, spacing: 8) {
                                instructionStep(1, "Go to **App Store Connect > Users and Access > Integrations > App Store Connect API**")
                                instructionStep(2, "Select the **Team Keys** tab (not Individual Keys)")
                                instructionStep(3, "Click the **+** button to generate a new key")
                                instructionStep(4, "Set Access to **Admin** and give the key a name")
                                instructionStep(5, "Click **Generate**")
                                instructionStep(6, "Copy the **Issuer ID** (shown at the top of the page) and the **Key ID** from the key row")
                                instructionStep(7, "Click the **Download** button on the new key row to save the .p8 file")
                                Text("The .p8 file can only be downloaded once. Store it securely.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .padding(.leading, 24)
                            }
                            .padding(.top, 8)
                        }
                    }
                }

                Divider()

                // Fields
                VStack(alignment: .leading, spacing: 16) {
                    labeledField("Issuer ID", hint: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx") {
                        TextField("Issuer ID", text: $issuerId)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }

                    labeledField("Key ID", hint: "10-character alphanumeric string") {
                        TextField("Key ID", text: $keyId)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Private Key (.p8)")
                            .font(.callout.weight(.medium))
                        HStack(spacing: 8) {
                            Button {
                                showFilePicker = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.badge.plus")
                                    Text(privateKeyFileName ?? "Choose .p8 File…")
                                }
                            }
                            .font(.callout)

                            if privateKeyFileName != nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.body)
                            }

                            Spacer()

                            Button {
                                save()
                            } label: {
                                if isSaving {
                                    ProgressView()
                                        .controlSize(.small)
                                        .padding(.horizontal, 8)
                                } else {
                                    Text("Save Credentials")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!isValid || isSaving)
                        }
                        Text("Upload your .p8 key file")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                if let error = saveError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let credError = ascManager.credentialsError {
                    Text(credError)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Action links
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        let settings = SettingsService.shared
                        let agent = AIAgent(rawValue: settings.defaultAgentCLI) ?? .claudeCode
                        let terminal = settings.resolveDefaultTerminal().terminal
                        let prompt = "Use the /asc-team-key-create skill to create a new App Store Connect API key, then call the asc_set_credentials MCP tool to fill the form so I can verify and save."

                        if terminal.isBuiltIn {
                            appState.showTerminal = true
                            let session = appState.terminalManager.createSession(projectPath: BlitzPaths.mcps.path)
                            let command = TerminalLauncher.buildAgentCommand(
                                projectPath: BlitzPaths.mcps.path,
                                agent: agent,
                                prompt: prompt,
                                skipPermissions: settings.skipAgentPermissions
                            )
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                session.sendCommand(command)
                            }
                        } else {
                            TerminalLauncher.launch(
                                projectPath: BlitzPaths.mcps.path,
                                agent: agent,
                                terminal: terminal,
                                prompt: prompt,
                                skipPermissions: settings.skipAgentPermissions
                            )
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                            Text("Setup with AI")
                            Image(systemName: "arrow.right")
                                .font(.caption)
                        }
                        .font(.callout.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)

                    Link(destination: URL(string: "https://appstoreconnect.apple.com/access/integrations/api")!) {
                        HStack(spacing: 6) {
                            Image(systemName: "key")
                            Text("Setup manually")
                            Image(systemName: "arrow.right")
                                .font(.caption)
                        }
                        .font(.callout.weight(.medium))
                    }
                }
            }
            .padding(28)
        }
        .frame(maxWidth: 540)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: ascManager.pendingCredentialValues) { _, pending in
            if let pending {
                issuerId = pending["issuerId"] ?? ""
                keyId = pending["keyId"] ?? ""
                privateKey = pending["privateKey"] ?? ""
                privateKeyFileName = pending["privateKeyFileName"]
                ascManager.pendingCredentialValues = nil
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [UTType(filenameExtension: "p8") ?? .data]
        ) { result in
            if case .success(let url) = result {
                if url.startAccessingSecurityScopedResource() {
                    defer { url.stopAccessingSecurityScopedResource() }
                    privateKey = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    privateKeyFileName = url.lastPathComponent
                }
            }
        }
    }

    @ViewBuilder
    private func instructionStep(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func labeledField<F: View>(_ label: String, hint: String, @ViewBuilder field: () -> F) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.callout.weight(.medium))
            field()
            Text(hint)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func save() {
        isSaving = true
        saveError = nil
        let creds = ASCCredentials(
            issuerId: issuerId.trimmingCharacters(in: .whitespaces),
            keyId: keyId.trimmingCharacters(in: .whitespaces),
            privateKey: privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        Task {
            do {
                try await ascManager.saveCredentials(
                    creds,
                    projectId: projectId,
                    bundleId: bundleId
                )
            } catch {
                saveError = error.localizedDescription
            }
            isSaving = false
        }
    }
}

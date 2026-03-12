import SwiftUI
import UniformTypeIdentifiers

struct ASCCredentialForm: View {
    var ascManager: ASCManager
    var projectId: String
    var bundleId: String?

    @State private var issuerId = ""
    @State private var keyId = ""
    @State private var privateKey = ""
    @State private var bundleIdInput = ""
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showFilePicker = false

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
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enter your API credentials to access App Store data.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Link("Create a key in App Store Connect \u{2192} Integrations",
                             destination: URL(string: "https://appstoreconnect.apple.com/access/integrations/api")!)
                            .font(.callout)
                    }
                    .fixedSize(horizontal: false, vertical: true)
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

                    labeledField("Private Key (.p8)", hint: "Paste the full PEM content or load from file") {
                        VStack(alignment: .trailing, spacing: 6) {
                            TextEditor(text: $privateKey)
                                .font(.system(.caption, design: .monospaced))
                                .frame(height: 120)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                )
                            Button("Load .p8 File…") {
                                showFilePicker = true
                            }
                            .font(.callout)
                        }
                    }

                    Divider()

                    labeledField("Bundle ID", hint: "Must match your app in App Store Connect (e.g. com.mycompany.myapp)") {
                        TextField("com.example.myapp", text: $bundleIdInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
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

                // Save button
                HStack {
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
            }
            .padding(28)
        }
        .frame(maxWidth: 540)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { bundleIdInput = bundleId ?? "" }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [UTType(filenameExtension: "p8") ?? .data]
        ) { result in
            if case .success(let url) = result {
                if url.startAccessingSecurityScopedResource() {
                    defer { url.stopAccessingSecurityScopedResource() }
                    privateKey = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                }
            }
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
        let resolvedBundleId = bundleIdInput.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                // Save bundle ID to project metadata if user entered/changed it
                if !resolvedBundleId.isEmpty {
                    let storage = ProjectStorage()
                    if var metadata = storage.readMetadata(projectId: projectId) {
                        metadata.bundleIdentifier = resolvedBundleId
                        try storage.writeMetadata(projectId: projectId, metadata: metadata)
                    }
                }
                try await ascManager.saveCredentials(
                    creds,
                    projectId: projectId,
                    bundleId: resolvedBundleId.isEmpty ? bundleId : resolvedBundleId
                )
            } catch {
                saveError = error.localizedDescription
            }
            isSaving = false
        }
    }
}

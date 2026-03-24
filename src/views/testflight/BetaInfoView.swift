import SwiftUI

struct BetaInfoView: View {
    var appState: AppState

    private var asc: ASCManager { appState.ascManager }
    @State private var selectedLocId: String = ""
    @State private var editDescription = ""
    @State private var editFeedbackEmail = ""
    @State private var editMarketingUrl = ""
    @State private var editPrivacyUrl = ""
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var saveSuccess = false

    var body: some View {
        ASCCredentialGate(
            ascManager: asc,
            projectId: appState.activeProjectId ?? "",
            bundleId: appState.activeProject?.metadata.bundleIdentifier
        ) {
            ASCTabContent(asc: asc, tab: .betaInfo, platform: appState.activeProject?.platform ?? .iOS) {
                betaInfoContent
            }
        }
        .task(id: appState.activeProjectId) { await asc.ensureTabData(.betaInfo) }
    }

    @ViewBuilder
    private var betaInfoContent: some View {
        let locs = asc.betaLocalizations
        let current = locs.first { $0.id == selectedLocId } ?? locs.first

        VStack(spacing: 0) {
            // Locale picker toolbar
            HStack {
                if !locs.isEmpty {
                    Picker("Locale", selection: $selectedLocId) {
                        ForEach(locs) { loc in
                            Text(loc.attributes.locale).tag(loc.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 180)
                    .onChange(of: locs.count) { _, _ in
                        if selectedLocId.isEmpty, let first = asc.betaLocalizations.first {
                            selectedLocId = first.id
                            loadLocalization(first)
                        }
                    }
                    .onAppear {
                        if selectedLocId.isEmpty, let first = locs.first {
                            selectedLocId = first.id
                            loadLocalization(first)
                        }
                    }
                    .onChange(of: selectedLocId) { _, newId in
                        if let loc = locs.first(where: { $0.id == newId }) {
                            loadLocalization(loc)
                        }
                    }
                }
                Spacer()
                if saveSuccess {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
                if let error = saveError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                Button {
                    save(locId: current?.id ?? selectedLocId)
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || current == nil)
                ASCTabRefreshButton(asc: asc, tab: .betaInfo, helpText: "Refresh beta info")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.background.secondary)

            Divider()

            if current == nil && !locs.isEmpty {
                ContentUnavailableView("Select a locale", systemImage: "doc.text")
            } else if locs.isEmpty {
                if asc.isTabLoading(.betaInfo) {
                    ASCTabLoadingPlaceholder(
                        title: "Loading Beta Info",
                        message: "Fetching beta app localizations and tester-facing copy."
                    )
                } else {
                    ContentUnavailableView(
                        "No Localizations",
                        systemImage: "doc.text",
                        description: Text("No beta app localizations found.")
                    )
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        editField("Beta Description",
                                  text: $editDescription,
                                  hint: "Describe what testers should focus on",
                                  multiline: true)

                        editField("Feedback Email",
                                  text: $editFeedbackEmail,
                                  hint: "Email for tester feedback")

                        editField("Marketing URL",
                                  text: $editMarketingUrl,
                                  hint: "https://example.com")

                        editField("Privacy Policy URL",
                                  text: $editPrivacyUrl,
                                  hint: "https://example.com/privacy")
                    }
                    .padding(24)
                }
            }
        }
    }

    @ViewBuilder
    private func editField(_ label: String, text: Binding<String>, hint: String, multiline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.callout.weight(.medium))
            if multiline {
                TextEditor(text: text)
                    .font(.body)
                    .frame(height: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            } else {
                TextField(hint, text: text)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func loadLocalization(_ loc: ASCBetaLocalization) {
        editDescription = loc.attributes.description ?? ""
        editFeedbackEmail = loc.attributes.feedbackEmail ?? ""
        editMarketingUrl = loc.attributes.marketingUrl ?? ""
        editPrivacyUrl = loc.attributes.privacyPolicyUrl ?? ""
        saveSuccess = false
        saveError = nil
    }

    private func save(locId: String) {
        guard !locId.isEmpty, let service = asc.service else { return }
        isSaving = true
        saveError = nil
        saveSuccess = false
        Task {
            do {
                try await service.patchBetaLocalization(
                    id: locId,
                    locale: "",
                    description: editDescription.isEmpty ? nil : editDescription,
                    feedbackEmail: editFeedbackEmail.isEmpty ? nil : editFeedbackEmail,
                    marketingUrl: editMarketingUrl.isEmpty ? nil : editMarketingUrl,
                    privacyPolicyUrl: editPrivacyUrl.isEmpty ? nil : editPrivacyUrl
                )
                saveSuccess = true
                // Refresh tab data
                await asc.refreshTabData(.betaInfo)
            } catch {
                saveError = error.localizedDescription
            }
            isSaving = false
        }
    }
}

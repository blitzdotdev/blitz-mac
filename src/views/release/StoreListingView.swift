import SwiftUI

struct StoreListingView: View {
    var appState: AppState

    private var asc: ASCManager { appState.ascManager }
    @FocusState private var focusedField: String?

    // Editable field values
    @State private var title: String = ""
    @State private var subtitle: String = ""
    @State private var descriptionText: String = ""
    @State private var keywords: String = ""
    @State private var promotionalText: String = ""
    @State private var marketingUrl: String = ""
    @State private var supportUrl: String = ""
    @State private var whatsNew: String = ""
    @State private var privacyPolicyUrl: String = ""

    @State private var isSaving = false

    private var currentLocale: String {
        asc.activeStoreListingLocale() ?? ""
    }

    private var selectedVersionBinding: Binding<String> {
        Binding(
            get: { asc.selectedVersion?.id ?? "" },
            set: { newValue in
                guard !newValue.isEmpty else { return }
                asc.prepareForVersionSelection(newValue)
                Task {
                    await asc.refreshTabData(.storeListing)
                    populateCurrentFields()
                }
            }
        )
    }

    private var selectedLocaleBinding: Binding<String> {
        Binding(
            get: { currentLocale },
            set: { newValue in
                asc.selectedStoreListingLocale = newValue
                populateCurrentFields()
            }
        )
    }

    var body: some View {
        ASCCredentialGate(
            appState: appState,
            ascManager: asc,
            projectId: appState.activeProjectId ?? "",
            bundleId: appState.activeProject?.metadata.bundleIdentifier
        ) {
            ASCTabContent(appState: appState, asc: asc, tab: .storeListing, platform: appState.activeProject?.platform ?? .iOS) {
                listingContent
            }
        }
        .task(id: "\(appState.activeProjectId ?? ""):\(asc.credentialActivationRevision)") {
            await asc.ensureTabData(.storeListing)
            populateCurrentFields()
            applyPendingValues()
        }
        .onChange(of: asc.selectedStoreListingLocale) { _, _ in
            guard focusedField == nil else { return }
            populateCurrentFields()
        }
        .onChange(of: asc.isTabLoading(.storeListing)) { wasLoading, isLoading in
            guard wasLoading, !isLoading else { return }
            guard focusedField == nil else { return }
            populateCurrentFields()
        }
        .onDisappear {
            Task { await flushChanges() }
        }
    }

    @ViewBuilder
    private var listingContent: some View {
        let locales = asc.localizations
        let current = asc.storeListingLocalization(locale: currentLocale)
        let isLoading = asc.isTabLoading(.storeListing)

        VStack(spacing: 0) {
            // Toolbar
            if asc.app != nil {
                ASCVersionPickerBar(
                    asc: asc,
                    selection: selectedVersionBinding
                ) {
                    if !locales.isEmpty {
                        Picker("Locale", selection: selectedLocaleBinding) {
                            ForEach(locales) { loc in
                                Text(loc.attributes.locale).tag(loc.attributes.locale)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 160)
                    }
                    if isSaving {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Saving…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let appId = asc.app?.id {
                        Link(destination: URL(string: "https://appstoreconnect.apple.com/apps/\(appId)/appstore")!) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.callout)
                        }
                        .help("Open in App Store Connect")
                    }
                    ASCTabRefreshButton(asc: asc, tab: .storeListing, helpText: "Refresh store listing data")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.background.secondary)
            }

            Divider()

            ScrollView {
                if current != nil {
                    VStack(alignment: .leading, spacing: 20) {
                        editableField("Privacy Policy URL", text: $privacyPolicyUrl, fieldKey: "privacyPolicyUrl")
                        editableField("Name", text: $title, fieldKey: "title", maxChars: 30)
                        editableField("Subtitle", text: $subtitle, fieldKey: "subtitle", maxChars: 30)
                        editableMultilineField("Description", text: $descriptionText, fieldKey: "description", maxChars: 4000)
                        editableField("Keywords", text: $keywords, fieldKey: "keywords", maxChars: 100)
                        editableMultilineField("Promotional Text", text: $promotionalText, fieldKey: "promotionalText", maxChars: 170)
                        editableField("Marketing URL", text: $marketingUrl, fieldKey: "marketingUrl")
                        editableField("Support URL", text: $supportUrl, fieldKey: "supportUrl")
                        editableMultilineField("What's New", text: $whatsNew, fieldKey: "whatsNew")
                    }
                    .padding(24)
                } else if asc.localizations.isEmpty {
                    if isLoading {
                        ASCTabLoadingPlaceholder(
                            title: "Loading Store Listing",
                            message: "Fetching localizations and editable metadata."
                        )
                    } else {
                        ContentUnavailableView(
                            "No Localizations",
                            systemImage: "text.page",
                            description: Text("No localizations found for the latest version.")
                        )
                        .padding(.top, 60)
                    }
                }
            }
        }
        .onChange(of: asc.pendingFormVersion) { _, _ in
            applyPendingValues()
        }
        .onChange(of: focusedField) { oldField, _ in
            if let oldField {
                Task { await saveField(oldField) }
            }
        }
    }

    private func populateCurrentFields() {
        populateFields(
            from: asc.storeListingLocalization(locale: currentLocale),
            infoLocalization: asc.appInfoLocalizationForLocale(currentLocale)
        )
    }

    private func populateFields(from loc: ASCVersionLocalization?, infoLocalization: ASCAppInfoLocalization?) {
        // name and subtitle come from appInfoLocalization, not version localization
        title = infoLocalization?.attributes.name ?? loc?.attributes.title ?? ""
        subtitle = infoLocalization?.attributes.subtitle ?? loc?.attributes.subtitle ?? ""
        privacyPolicyUrl = infoLocalization?.attributes.privacyPolicyUrl ?? ""
        // The rest come from version localization
        descriptionText = loc?.attributes.description ?? ""
        keywords = loc?.attributes.keywords ?? ""
        promotionalText = loc?.attributes.promotionalText ?? ""
        marketingUrl = loc?.attributes.marketingUrl ?? ""
        supportUrl = loc?.attributes.supportUrl ?? ""
        whatsNew = loc?.attributes.whatsNew ?? ""
    }

    private func applyPendingValues() {
        guard let pending = asc.pendingFormValues["storeListing"] else { return }
        for (field, value) in pending {
            switch field {
            case "title", "name": title = value
            case "subtitle": subtitle = value
            case "description": descriptionText = value
            case "keywords": keywords = value
            case "promotionalText": promotionalText = value
            case "marketingUrl": marketingUrl = value
            case "supportUrl": supportUrl = value
            case "whatsNew": whatsNew = value
            case "privacyPolicyUrl": privacyPolicyUrl = value
            default: break
            }
        }
    }

    /// Fields that live on appInfoLocalizations (name, subtitle, privacyPolicyUrl)
    /// vs appStoreVersionLocalizations (description, keywords, whatsNew, etc.)
    private static let appInfoLocFields: Set<String> = ["title", "subtitle", "privacyPolicyUrl"]

    private func saveField(_ field: String) async {
        let value: String
        switch field {
        case "title": value = title
        case "subtitle": value = subtitle
        case "description": value = descriptionText
        case "keywords": value = keywords
        case "promotionalText": value = promotionalText
        case "marketingUrl": value = marketingUrl
        case "supportUrl": value = supportUrl
        case "whatsNew": value = whatsNew
        case "privacyPolicyUrl": value = privacyPolicyUrl
        default: return
        }

        isSaving = true
        if Self.appInfoLocFields.contains(field) {
            // These fields live on appInfoLocalizations, not version localizations
            await asc.updateAppInfoLocalizationField(field, value: value, locale: currentLocale)
        } else {
            await asc.updateLocalizationField(field, value: value, locale: currentLocale)
        }
        isSaving = false
    }

    private func flushChanges() async {
        // Save any unsaved changes on disappear
        if let focused = focusedField {
            await saveField(focused)
        }
    }

    @ViewBuilder
    private func editableField(_ label: String, text: Binding<String>, fieldKey: String, maxChars: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                if let max = maxChars {
                    Spacer()
                    Text("\(text.wrappedValue.count)/\(max)")
                        .font(.caption)
                        .foregroundStyle(text.wrappedValue.count > max ? .red : .secondary)
                }
            }
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: fieldKey)
        }
    }

    @ViewBuilder
    private func editableMultilineField(_ label: String, text: Binding<String>, fieldKey: String, maxChars: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                if let max = maxChars {
                    Spacer()
                    Text("\(text.wrappedValue.count)/\(max)")
                        .font(.caption)
                        .foregroundStyle(text.wrappedValue.count > max ? .red : .secondary)
                }
            }
            TextEditor(text: text)
                .font(.body)
                .frame(minHeight: 80, maxHeight: 200)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .focused($focusedField, equals: fieldKey)
        }
    }
}

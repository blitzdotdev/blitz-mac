import SwiftUI

struct StoreListingView: View {
    var appState: AppState

    private var asc: ASCManager { appState.ascManager }
    @State private var selectedLocale: String = ""
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
    @State private var lastSavedField: String?

    var body: some View {
        ASCCredentialGate(
            ascManager: asc,
            projectId: appState.activeProjectId ?? "",
            bundleId: appState.activeProject?.metadata.bundleIdentifier
        ) {
            ASCTabContent(asc: asc, tab: .storeListing) {
                listingContent
            }
        }
        .task { await asc.fetchTabData(.storeListing) }
        .onDisappear {
            Task { await flushChanges() }
        }
    }

    @ViewBuilder
    private var listingContent: some View {
        let locales = asc.localizations
        let current = locales.first { $0.attributes.locale == selectedLocale }
            ?? locales.first

        VStack(spacing: 0) {
            // Toolbar
            HStack {
                if !locales.isEmpty {
                    Picker("Locale", selection: $selectedLocale) {
                        ForEach(locales) { loc in
                            Text(loc.attributes.locale).tag(loc.attributes.locale)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 160)
                    .onChange(of: locales.count) { _, _ in
                        if selectedLocale.isEmpty, let first = asc.localizations.first {
                            selectedLocale = first.attributes.locale
                        }
                    }
                    .onAppear {
                        if selectedLocale.isEmpty, let first = locales.first {
                            selectedLocale = first.attributes.locale
                        }
                    }
                }
                Spacer()
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
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.background.secondary)

            Divider()

            ScrollView {
                if current != nil {
                    VStack(alignment: .leading, spacing: 20) {
                        editableField("Privacy Policy URL", text: $privacyPolicyUrl, fieldKey: "privacyPolicyUrl")
                        Divider()
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
                    ContentUnavailableView(
                        "No Localizations",
                        systemImage: "text.page",
                        description: Text("No localizations found for the latest version.")
                    )
                    .padding(.top, 60)
                }
            }
        }
        .onChange(of: current?.id) { _, _ in
            populateFields(from: current)
        }
        .onAppear {
            populateFields(from: current)
            applyPendingValues()
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

    private func populateFields(from loc: ASCVersionLocalization?) {
        // name and subtitle come from appInfoLocalization, not version localization
        let infoLoc = asc.appInfoLocalization
        title = infoLoc?.attributes.name ?? loc?.attributes.title ?? ""
        subtitle = infoLoc?.attributes.subtitle ?? loc?.attributes.subtitle ?? ""
        privacyPolicyUrl = infoLoc?.attributes.privacyPolicyUrl ?? ""
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
            await asc.updateAppInfoLocalizationField(field, value: value)
        } else {
            guard let locId = (asc.localizations.first { $0.attributes.locale == selectedLocale }
                                ?? asc.localizations.first)?.id else {
                isSaving = false
                return
            }
            await asc.updateLocalizationField(field, value: value, locId: locId)
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
            Divider()
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
            Divider()
        }
    }
}

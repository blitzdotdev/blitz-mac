import SwiftUI
import CryptoKit

/// Multi-phase inline view for registering a bundle ID, enabling capabilities,
/// and guiding the user to create their app in App Store Connect.
struct BundleIDSetupView: View {
    var asc: ASCManager
    var tab: AppTab
    var platform: ProjectPlatform = .iOS

    enum Phase {
        case form       // Step 1: fill out org + app name + capabilities
        case creating   // Registering bundle ID + enabling capabilities
        case manual     // Step 2: manual action — create app in ASC
        case confirming // Checking if app exists in ASC
    }

    @State private var phase: Phase = .form
    @State private var organization = ""
    @State private var appName = ""
    @State private var selectedCapabilities: Set<String> = []
    @State private var progressMessage = ""
    @State private var error: String?
    @State private var createdBundleId = ""
    @State private var capabilitiesEnabled = 0
    @State private var showAdditional = false

    // Auto-create via AI agent
    @State private var showAppleIDLogin = false

    private var selectedAgentName: String {
        (AIAgent(rawValue: SettingsService.shared.defaultAgentCLI) ?? .claudeCode).displayName
    }

    // Capabilities supported by the ASC API (can be enabled automatically)
    private static let capabilities: [(type: String, name: String)] = [
        ("PUSH_NOTIFICATIONS", "Push Notifications"),
        ("IN_APP_PURCHASE", "In-App Purchase"),
        ("APPLE_ID_AUTH", "Sign in with Apple"),
        ("ICLOUD", "iCloud"),
        ("GAME_CENTER", "Game Center"),
        ("APPLE_PAY", "Apple Pay"),
        ("APP_GROUPS", "App Groups"),
        ("ASSOCIATED_DOMAINS", "Associated Domains"),
        ("HEALTHKIT", "HealthKit"),
        ("HOMEKIT", "HomeKit"),
        ("SIRIKIT", "Siri"),
        ("NFC_TAG_READING", "NFC Tag Reading"),
        ("WALLET", "Wallet"),
        ("MAPS", "Maps"),
        ("DATA_PROTECTION", "Data Protection"),
        ("AUTOFILL_CREDENTIAL_PROVIDER", "AutoFill Credential Provider"),
        ("ACCESS_WIFI_INFORMATION", "Access WiFi Information"),
        ("CLASSKIT", "ClassKit"),
        ("NETWORK_EXTENSIONS", "Network Extensions"),
        ("PERSONAL_VPN", "Personal VPN"),
        ("MULTIPATH", "Multipath"),
        ("HOT_SPOT", "Hotspot"),
        ("WIRELESS_ACCESSORY_CONFIGURATION", "Wireless Accessory"),
        ("INTER_APP_AUDIO", "Inter-App Audio"),
        ("NETWORK_CUSTOM_PROTOCOL", "Custom Network Protocol"),
        ("COREMEDIA_HLS_LOW_LATENCY", "HLS Low Latency"),
        ("SYSTEM_EXTENSION_INSTALL", "System Extension"),
        ("USER_MANAGEMENT", "User Management"),
    ]

    // Additional capabilities only configurable through the Apple Developer portal
    private static let portalOnlyCapabilities: [String] = [
        "5G Network Slicing",
        "App Attest",
        "Background Modes",
        "Communication Notifications",
        "Extended Virtual Addressing",
        "Family Controls",
        "Fonts",
        "Group Activities",
        "Head Pose",
        "HealthKit Estimate Recalibration",
        "HLS Interstitial Previews",
        "Increased Debugging Memory Limit",
        "Journaling Suggestions",
        "Keychain Sharing",
        "Matter Allow Setup Payload",
        "MDM Managed Associated Domains",
        "Media Device Discovery",
        "Messages Collaboration",
        "On Demand Install Capable",
        "Push to Talk",
        "Sensitive Content Analysis",
        "Shared with You",
        "SIM Inserted for Wireless Carriers",
        "Spatial Audio Profile",
        "Sustained Execution",
        "Time Sensitive Notifications",
        "WeatherKit",
    ]

    private func sanitize(_ input: String) -> String {
        input.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    private var bundleIdPreview: String {
        let org = sanitize(organization)
        let app = sanitize(appName)
        guard !org.isEmpty, !app.isEmpty else { return "com...." }
        return "com.\(org).\(app)"
    }

    private var isFormValid: Bool {
        !sanitize(organization).isEmpty && !sanitize(appName).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch phase {
                case .form:
                    formContent
                case .creating:
                    creatingContent
                case .manual:
                    manualContent
                case .confirming:
                    confirmingContent
                }
            }
            .padding(32)
            .frame(maxWidth: 540, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: prefill)
        .sheet(isPresented: $showAppleIDLogin) {
            AppleIDLoginSheet(
                subtitle: "Sign in to let Claude register your app in App Store Connect."
            ) { session in
                handleAutoCreateSession(session)
            }
        }
    }

    // MARK: - Phase 1: Form

    @ViewBuilder
    private var formContent: some View {
        // Header
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .font(.title2)
                .foregroundStyle(.blue)
            Text("Register Your Bundle ID")
                .font(.title2.weight(.semibold))
        }
        Text("Create a bundle ID to connect your app to App Store Connect.")
            .font(.callout)
            .foregroundStyle(.secondary)

        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Text("Bundle IDs cannot be changed once registered. Choose carefully.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Divider()

        // Fields
        VStack(alignment: .leading, spacing: 16) {
            labeledField("Organization", hint: "Your company or personal identifier") {
                TextField("mycompany", text: $organization)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            labeledField("App Name", hint: "Your app's name") {
                TextField("myapp", text: $appName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            HStack(spacing: 6) {
                Text("Bundle ID:")
                    .font(.callout.weight(.medium))
                Text(bundleIdPreview)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(isFormValid ? .primary : .secondary)
            }
        }

        Divider()

        // Capabilities
        VStack(alignment: .leading, spacing: 8) {
            Text("Capabilities")
                .font(.callout.weight(.medium))
            Text("Select capabilities your app needs. You can add more later in the Apple Developer portal.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 6) {
                ForEach(Self.capabilities, id: \.type) { cap in
                    Toggle(cap.name, isOn: Binding(
                        get: { selectedCapabilities.contains(cap.type) },
                        set: { selected in
                            if selected { selectedCapabilities.insert(cap.type) }
                            else { selectedCapabilities.remove(cap.type) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.callout)
                }
            }
            .padding(.top, 4)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showAdditional.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showAdditional ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text("Additional Capabilities (\(Self.portalOnlyCapabilities.count))")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)

            if showAdditional {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("These must be enabled manually in the ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        + Text("[Developer portal](https://developer.apple.com/account/resources/identifiers/list)")
                            .font(.caption)
                    }

                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 6) {
                        ForEach(Self.portalOnlyCapabilities, id: \.self) { name in
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.square")
                                    .font(.callout)
                                    .foregroundStyle(.quaternary)
                                Text(name)
                                    .font(.callout)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .padding(10)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }

        if let error {
            Text(error)
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }

        Divider()

        // Submit button
        HStack {
            Spacer()
            Button("Register Bundle ID") {
                registerBundleId()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isFormValid)
        }
    }

    // MARK: - Phase 2: Creating

    @ViewBuilder
    private var creatingContent: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(progressMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - Phase 3: Manual

    @ViewBuilder
    private var manualContent: some View {
        // Success header
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
            Text("Bundle ID Registered")
                .font(.title2.weight(.semibold))
        }

        VStack(alignment: .leading, spacing: 4) {
            Text(createdBundleId)
                .font(.system(.body, design: .monospaced))
            if capabilitiesEnabled > 0 {
                Text("\(capabilitiesEnabled) capability(ies) enabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Divider()

        VStack(alignment: .leading, spacing: 12) {
            Text("Now create your app in App Store Connect.")
                .font(.callout)
            Text("Make sure to select the bundle ID you just registered:")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(createdBundleId)
                .font(.system(.callout, design: .monospaced).weight(.medium))
                .padding(8)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Button {
                showAppleIDLogin = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                    Text("Automatically create using \(selectedAgentName)")
                }
                .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)

            Link("Open App Store Connect \u{2192}",
                 destination: URL(string: "https://appstoreconnect.apple.com/apps")!)
                .font(.callout)
        }

        Divider()

        VStack(alignment: .leading, spacing: 12) {
            Text("Did you create your app?")
                .font(.callout.weight(.medium))

            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Confirm") {
                    confirmAppCreated()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Phase 4: Confirming

    @ViewBuilder
    private var confirmingContent: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Checking App Store Connect\u{2026}")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - Actions

    private func prefill() {
        guard let projectId = asc.loadedProjectId else { return }
        let storage = ProjectStorage()
        guard let metadata = storage.readMetadata(projectId: projectId) else { return }

        // Pre-fill from existing bundle ID if it looks like com.xxx.yyy
        if let existingBundleId = metadata.bundleIdentifier,
           !existingBundleId.isEmpty {
            let parts = existingBundleId.split(separator: ".")
            if parts.count >= 3 && parts[0] == "com" {
                organization = String(parts[1])
                appName = parts.dropFirst(2).joined(separator: ".")
                return
            }
        }

        // Otherwise, pre-fill app name from project name
        appName = sanitize(metadata.name)
    }

    private func registerBundleId() {
        guard let service = asc.service else {
            error = "ASC service not configured"
            return
        }

        error = nil
        phase = .creating
        let bundleId = bundleIdPreview
        let bundleName = appName
        let caps = Array(selectedCapabilities)

        Task {
            do {
                progressMessage = "Registering bundle ID\u{2026}"

                // Check if bundle ID already exists; register if not
                var resourceId: String
                if let existing = try await service.fetchBundleId(identifier: bundleId) {
                    resourceId = existing.id
                } else {
                    let bundleIdPlatform = platform == .macOS ? "MAC_OS" : "IOS"
                    let created = try await service.registerBundleId(identifier: bundleId, name: bundleName, platform: bundleIdPlatform)
                    resourceId = created.id
                }

                // Enable selected capabilities
                var enabled = 0
                for cap in caps {
                    let capName = Self.capabilities.first(where: { $0.type == cap })?.name ?? cap
                    progressMessage = "Enabling \(capName)\u{2026}"
                    do {
                        try await service.enableCapability(bundleIdResourceId: resourceId, capabilityType: cap)
                        enabled += 1
                    } catch let err as ASCError {
                        if case .httpError(409, _) = err {
                            enabled += 1  // Already enabled, counts as success
                        }
                        // Other capability errors: skip silently, don't block the flow
                    }
                }

                // Save bundle ID to project metadata
                if let projectId = asc.loadedProjectId {
                    let storage = ProjectStorage()
                    if var metadata = storage.readMetadata(projectId: projectId) {
                        metadata.bundleIdentifier = bundleId
                        try storage.writeMetadata(projectId: projectId, metadata: metadata)
                    }
                }

                createdBundleId = bundleId
                capabilitiesEnabled = enabled
                phase = .manual

            } catch {
                self.error = error.localizedDescription
                phase = .form
            }
        }
    }

    private func confirmAppCreated() {
        error = nil
        phase = .confirming

        Task {
            await asc.fetchApp(bundleId: createdBundleId)

            if asc.app != nil {
                asc.credentialsError = nil
                asc.resetTabState()
                await asc.fetchTabData(tab)
            } else {
                error = "App not found in App Store Connect. Make sure you created the app with bundle ID \"\(createdBundleId)\" and try again."
                phase = .manual
            }
        }
    }

    // MARK: - Auto-create via Claude Code

    private func handleAutoCreateSession(_ session: IrisSession) {
        try? session.save()

        Task {
            // Email is extracted in the WebView via sync XHR. If that failed
            // (e.g. page navigated away before XHR completed), fall back to
            // a direct URLSession request with an ephemeral config.
            var email = session.email
            if email == nil {
                email = await fetchAppleIDEmailFallback(session: session)
            }

            // Bridge cookies into the ASC CLI keychain so `asc apps create` just works
            bridgeToASCKeychain(session: session, email: email)

            // Launch Terminal running Claude Code
            launchClaudeCodeForAppCreate(bundleId: createdBundleId, email: email)
        }
    }

    /// Fallback email extraction using an ephemeral URLSession (no shared cookie
    /// store interference). Used when the WebView sync XHR didn't capture the email.
    private func fetchAppleIDEmailFallback(session: IrisSession) async -> String? {
        guard let url = URL(string: "https://appstoreconnect.apple.com/olympus/v1/session") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(
            session.cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "),
            forHTTPHeaderField: "Cookie"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        let urlSession = URLSession(configuration: config)

        guard let (data, _) = try? await urlSession.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = json["user"] as? [String: Any],
              let email = user["emailAddress"] as? String else {
            return nil
        }
        return email
    }

    private func bridgeToASCKeychain(session: IrisSession, email: String?) {
        // Build the persisted-session JSON that the ASC CLI expects
        var cookiesByDomain: [String: [[String: Any]]] = [:]
        for cookie in session.cookies {
            let domainKey = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            let cookieDict: [String: Any] = [
                "name": cookie.name,
                "value": cookie.value,
                "domain": cookie.domain,
                "path": cookie.path,
                "secure": true,
                "http_only": true,
            ]
            cookiesByDomain[domainKey, default: []].append(cookieDict)
        }

        let persistedSession: [String: Any] = [
            "version": 1,
            "updated_at": ISO8601DateFormatter().string(from: Date()),
            "cookies": cookiesByDomain,
        ]

        guard let sessionData = try? JSONSerialization.data(withJSONObject: persistedSession) else { return }

        // If we resolved the email, store under the sha256 key ASC looks up by email
        if let email {
            let normalized = email.lowercased().trimmingCharacters(in: .whitespaces)
            let hashString = SHA256.hash(data: Data(normalized.utf8))
                .map { String(format: "%02x", $0) }.joined()

            writeASCKeychainEntry(service: "asc-web-session",
                                  account: "asc:web-session:\(hashString)",
                                  data: sessionData)
            writeASCKeychainEntry(service: "asc-web-session",
                                  account: "asc:web-session:last",
                                  data: Data(hashString.utf8))
        }

        // Always also store under a well-known key so the skill can look it up
        writeASCKeychainEntry(service: "asc-web-session",
                              account: "asc:web-session:blitz",
                              data: sessionData)
    }

    private func writeASCKeychainEntry(service: String, account: String, data: Data) {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func launchClaudeCodeForAppCreate(bundleId: String, email: String?) {
        let appSuffix = bundleId.split(separator: ".").last.map(String.init) ?? bundleId
        let sku = appSuffix.uppercased() + String(format: "%04d", Int.random(in: 1000...9999))
        var prompt = "Create a new App Store Connect app for \(bundleId) with SKU \(sku)"
        if let email {
            prompt += " and apple-id \(email)"
        }
        prompt += ". Ask the user what primary language they want (e.g. en-US for English), then use the /asc-app-create-ui skill."

        var projectPath: String? = nil
        if let projectId = asc.loadedProjectId {
            projectPath = ProjectStorage().baseDirectory.appendingPathComponent(projectId).path
        }

        let settings = SettingsService.shared
        let agent = AIAgent(rawValue: settings.defaultAgentCLI) ?? .claudeCode
        let terminal = TerminalApp.from(settings.defaultTerminal)
        TerminalLauncher.launch(projectPath: projectPath, agent: agent, terminal: terminal, prompt: prompt)
    }

    // MARK: - Helpers

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
}

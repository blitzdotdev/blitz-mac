import SwiftUI

struct ReviewView: View {
    var appState: AppState

    private var asc: ASCManager { appState.ascManager }

    @State private var ageRatingExpanded = false
    @State private var contactExpanded = true
    @State private var isSavingAgeRating = false
    @State private var isSavingContact = false

    // Age Rating boolean fields
    @State private var arGambling = false
    @State private var arMessaging = false
    @State private var arWebAccess = false
    @State private var arUGC = false
    @State private var arAdvertising = false
    @State private var arLootBox = false
    @State private var arHealth = false
    @State private var arParental = false
    @State private var arAgeAssurance = false

    // Age Rating string fields (NONE / INFREQUENT_OR_MILD / FREQUENT_OR_INTENSE)
    @State private var arAlcohol = "NONE"
    @State private var arContests = "NONE"
    @State private var arGamblingSim = "NONE"
    @State private var arGuns = "NONE"
    @State private var arHorror = "NONE"
    @State private var arMature = "NONE"
    @State private var arMedical = "NONE"
    @State private var arProfanity = "NONE"
    @State private var arSexGraphic = "NONE"
    @State private var arSex = "NONE"
    @State private var arViolenceCartoon = "NONE"
    @State private var arViolenceRealistic = "NONE"
    @State private var arViolenceProlonged = "NONE"

    // Review contact fields
    @State private var contactFirstName = ""
    @State private var contactLastName = ""
    @State private var contactEmail = ""
    @State private var contactPhone = ""
    @State private var contactNotes = ""
    @State private var demoRequired = false
    @State private var demoName = ""
    @State private var demoPassword = ""
    @FocusState private var contactFocused: String?

    // Build & Compliance
    @State private var selectedBuild = ""
    @State private var usesEncryption = false

    private let threeLevels = ["NONE", "INFREQUENT_OR_MILD", "FREQUENT_OR_INTENSE"]

    private var contactRequiredFieldsFilled: Bool {
        !contactFirstName.isEmpty && !contactLastName.isEmpty
            && !contactEmail.isEmpty && !contactPhone.isEmpty
    }

    var body: some View {
        ASCCredentialGate(
            appState: appState,
            ascManager: asc,
            projectId: appState.activeProjectId ?? "",
            bundleId: appState.activeProject?.metadata.bundleIdentifier
        ) {
            ASCTabContent(appState: appState, asc: asc, tab: .review, platform: appState.activeProject?.platform ?? .iOS) {
                reviewContent
            }
        }
        .task(id: "\(appState.activeProjectId ?? ""):\(asc.credentialActivationRevision)") {
            await asc.ensureTabData(.review)
        }
        .onChange(of: asc.appStoreVersions.map(\.id)) { _, _ in
            guard let appId = asc.app?.id else { return }
            // Load cached rejection feedback for the pending version
            let pendingVersion = asc.appStoreVersions.first(where: {
                let s = $0.attributes.appStoreState ?? ""
                return s != "READY_FOR_SALE" && s != "REMOVED_FROM_SALE"
                    && s != "DEVELOPER_REMOVED_FROM_SALE" && !s.isEmpty
            })
            asc.loadCachedFeedback(appId: appId, versionString: pendingVersion?.attributes.versionString)
        }
    }

    @ViewBuilder
    private var reviewContent: some View {
        let latest = asc.appStoreVersions.first
        let feedbackVersion = asc.feedbackDisplayVersion(from: asc.appStoreVersions)
        let isLoading = asc.isTabLoading(.review)

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Review")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    ASCTabRefreshButton(asc: asc, tab: .review, helpText: "Refresh review data")
                }

                // Current version status card
                if let version = latest {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Version \(version.attributes.versionString)")
                                .font(.title3.weight(.semibold))
                            Spacer()
                            stateBadge(version.attributes.appStoreState ?? "Unknown")
                        }
                        if let date = version.attributes.createdDate {
                            Text("Created \(ascShortDate(date))")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                    .background(.background.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    // Rejection detail — shown when rejected, or when cached feedback persists after re-submission
                    if let feedbackVersion,
                       feedbackVersion.id == version.id
                        || asc.latestSubmissionItems.contains(where: { $0.attributes.state == "REJECTED" }) {
                        RejectionCardView(asc: asc, version: feedbackVersion) {
                            Text("Update your review info below and re-submit when ready.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Age Rating
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation { ageRatingExpanded.toggle() }
                    } label: {
                        HStack {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .rotationEffect(.degrees(ageRatingExpanded ? 90 : 0))
                                .animation(.easeInOut(duration: 0.15), value: ageRatingExpanded)
                            Text("Age Rating")
                                .font(.headline)
                            Spacer()
                            if asc.ageRatingDeclaration != nil {
                                Text("Configured")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.green.opacity(0.15))
                                    .foregroundStyle(.green)
                                    .clipShape(Capsule())
                            } else if isLoading {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Loading…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Text("Not set")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if ageRatingExpanded {
                        ageRatingForm
                    }
                }
                .padding(16)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // Review Contact
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation { contactExpanded.toggle() }
                    } label: {
                        HStack {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .rotationEffect(.degrees(contactExpanded ? 90 : 0))
                                .animation(.easeInOut(duration: 0.15), value: contactExpanded)
                            Text("Review Contact")
                                .font(.headline)
                            Spacer()
                            if let rd = asc.reviewDetail,
                               rd.attributes.contactFirstName != nil {
                                Text("\(rd.attributes.contactFirstName ?? "") \(rd.attributes.contactLastName ?? "")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if isLoading {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Loading…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Text("Not configured")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if contactExpanded {
                        reviewContactForm
                    }
                }
                .padding(16)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // Build & Compliance
                VStack(alignment: .leading, spacing: 16) {
                    Text("Build & Compliance")
                        .font(.headline)

                    if asc.builds.isEmpty {
                        if isLoading {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Loading builds and review history…")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("No builds available. Upload a build via Xcode or Transporter.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("Build", selection: $selectedBuild) {
                            Text("Select a build…").tag("")
                            ForEach(asc.builds.filter { $0.attributes.processingState == "VALID" }) { build in
                                Text("\(build.attributes.version) (\(ascShortDate(build.attributes.uploadedDate ?? "")))")
                                    .tag(build.id)
                            }
                        }

                        Toggle("Uses non-exempt encryption", isOn: $usesEncryption)
                            .onChange(of: usesEncryption) { _, newValue in
                                guard !selectedBuild.isEmpty else { return }
                                Task {
                                    try? await asc.service?.patchBuildEncryption(
                                        buildId: selectedBuild,
                                        usesNonExemptEncryption: newValue
                                    )
                                }
                            }
                    }
                }
                .padding(16)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // All versions
                if asc.appStoreVersions.count > 1 {
                    Text("All Versions")
                        .font(.headline)

                    VStack(spacing: 0) {
                        ForEach(Array(asc.appStoreVersions.enumerated()), id: \.element.id) { idx, version in
                            HStack {
                                Text(version.attributes.versionString)
                                    .font(.body.weight(.medium))
                                    .frame(width: 80, alignment: .leading)
                                stateBadge(version.attributes.appStoreState ?? "Unknown")
                                if version.attributes.appStoreState != "REJECTED",
                                   wasVersionPreviouslyRejected(version) {
                                    Text("Previously Rejected")
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.red.opacity(0.1))
                                        .foregroundStyle(.red)
                                        .clipShape(Capsule())
                                }
                                Spacer()
                                if let date = version.attributes.createdDate {
                                    Text(ascShortDate(date))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            if idx < asc.appStoreVersions.count - 1 {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                    .background(.background.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(24)
        }
        .onAppear {
            populateAgeRating()
            populateContact()
            applyPendingValues()
            syncSelectedBuild()
        }
        .onChange(of: asc.ageRatingDeclaration?.id) { _, _ in populateAgeRating() }
        .onChange(of: asc.reviewDetail?.id) { _, _ in populateContact() }
        .onChange(of: asc.pendingFormVersion) { _, _ in applyPendingValues() }
        .onChange(of: asc.builds.map(\.id)) { _, _ in syncSelectedBuild() }
        .onChange(of: contactFocused) { _, _ in
            // Don't auto-save contact — requires all required fields.
            // User saves explicitly via the "Save Contact" button.
        }
    }

    // MARK: - Age Rating Form

    @ViewBuilder
    private var ageRatingForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                Text("Boolean Fields").font(.callout.weight(.medium)).padding(.top, 8)
                Toggle("Gambling", isOn: $arGambling)
                Toggle("Messaging & Chat", isOn: $arMessaging)
                Toggle("Unrestricted Web Access", isOn: $arWebAccess)
                Toggle("User Generated Content", isOn: $arUGC)
                Toggle("Advertising", isOn: $arAdvertising)
                Toggle("Loot Box", isOn: $arLootBox)
                Toggle("Health or Wellness Topics", isOn: $arHealth)
                Toggle("Parental Controls", isOn: $arParental)
                Toggle("Age Assurance", isOn: $arAgeAssurance)
            }

            Divider()

            Group {
                Text("Frequency Fields").font(.callout.weight(.medium))
                threeLevelPicker("Alcohol/Tobacco/Drug Use", selection: $arAlcohol)
                threeLevelPicker("Contests", selection: $arContests)
                threeLevelPicker("Simulated Gambling", selection: $arGamblingSim)
                threeLevelPicker("Guns or Other Weapons", selection: $arGuns)
                threeLevelPicker("Horror or Fear Themes", selection: $arHorror)
                threeLevelPicker("Mature or Suggestive Themes", selection: $arMature)
                threeLevelPicker("Medical or Treatment Info", selection: $arMedical)
                threeLevelPicker("Profanity or Crude Humor", selection: $arProfanity)
            }

            Group {
                threeLevelPicker("Sexual Content (Graphic/Nudity)", selection: $arSexGraphic)
                threeLevelPicker("Sexual Content or Nudity", selection: $arSex)
                threeLevelPicker("Violence (Cartoon/Fantasy)", selection: $arViolenceCartoon)
                threeLevelPicker("Violence (Realistic)", selection: $arViolenceRealistic)
                threeLevelPicker("Violence (Prolonged/Graphic/Sadistic)", selection: $arViolenceProlonged)
            }

            HStack {
                Spacer()
                Button("Save Age Rating") {
                    Task { await saveAgeRating() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSavingAgeRating)

                if isSavingAgeRating {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.top, 8)
        }
        .padding(.top, 8)
    }

    private func threeLevelPicker(_ label: String, selection: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Picker("", selection: selection) {
                Text("None").tag("NONE")
                Text("Infrequent or Mild").tag("INFREQUENT_OR_MILD")
                Text("Frequent or Intense").tag("FREQUENT_OR_INTENSE")
            }
            .frame(width: 220)
        }
    }

    // MARK: - Review Contact Form

    @ViewBuilder
    private var reviewContactForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("First Name").font(.caption).foregroundStyle(.secondary)
                    TextField("First Name", text: $contactFirstName)
                        .textFieldStyle(.roundedBorder)
                        .focused($contactFocused, equals: "firstName")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last Name").font(.caption).foregroundStyle(.secondary)
                    TextField("Last Name", text: $contactLastName)
                        .textFieldStyle(.roundedBorder)
                        .focused($contactFocused, equals: "lastName")
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Email").font(.caption).foregroundStyle(.secondary)
                TextField("email@example.com", text: $contactEmail)
                    .textFieldStyle(.roundedBorder)
                    .focused($contactFocused, equals: "email")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Phone").font(.caption).foregroundStyle(.secondary)
                TextField("+1 650 555 0100", text: $contactPhone)
                    .textFieldStyle(.roundedBorder)
                    .focused($contactFocused, equals: "phone")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Notes").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $contactNotes)
                    .font(.body)
                    .frame(minHeight: 60, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.background.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    .focused($contactFocused, equals: "notes")
            }

            Toggle("Demo account required", isOn: $demoRequired)

            if demoRequired {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Username").font(.caption).foregroundStyle(.secondary)
                        TextField("Demo username", text: $demoName)
                            .textFieldStyle(.roundedBorder)
                            .focused($contactFocused, equals: "demoName")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Password").font(.caption).foregroundStyle(.secondary)
                        SecureField("Demo password", text: $demoPassword)
                            .textFieldStyle(.roundedBorder)
                            .focused($contactFocused, equals: "demoPassword")
                    }
                }
            }

            if let error = asc.writeError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                if isSavingContact {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Saving…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Save Contact") {
                    Task { await saveContact() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSavingContact || !contactRequiredFieldsFilled)
            }
            .padding(.top, 8)
        }
        .padding(.top, 8)
    }

    // MARK: - Data Population

    private func populateAgeRating() {
        guard let ar = asc.ageRatingDeclaration?.attributes else { return }
        arGambling = ar.gambling ?? false
        arMessaging = ar.messagingAndChat ?? false
        arWebAccess = ar.unrestrictedWebAccess ?? false
        arUGC = ar.userGeneratedContent ?? false
        arAdvertising = ar.advertising ?? false
        arLootBox = ar.lootBox ?? false
        arHealth = ar.healthOrWellnessTopics ?? false
        arParental = ar.parentalControls ?? false
        arAgeAssurance = ar.ageAssurance ?? false

        arAlcohol = ar.alcoholTobaccoOrDrugUseOrReferences ?? "NONE"
        arContests = ar.contests ?? "NONE"
        arGamblingSim = ar.gamblingSimulated ?? "NONE"
        arGuns = ar.gunsOrOtherWeapons ?? "NONE"
        arHorror = ar.horrorOrFearThemes ?? "NONE"
        arMature = ar.matureOrSuggestiveThemes ?? "NONE"
        arMedical = ar.medicalOrTreatmentInformation ?? "NONE"
        arProfanity = ar.profanityOrCrudeHumor ?? "NONE"
        arSexGraphic = ar.sexualContentGraphicAndNudity ?? "NONE"
        arSex = ar.sexualContentOrNudity ?? "NONE"
        arViolenceCartoon = ar.violenceCartoonOrFantasy ?? "NONE"
        arViolenceRealistic = ar.violenceRealistic ?? "NONE"
        arViolenceProlonged = ar.violenceRealisticProlongedGraphicOrSadistic ?? "NONE"
    }

    private func populateContact() {
        guard let rd = asc.reviewDetail?.attributes else { return }
        contactFirstName = rd.contactFirstName ?? ""
        contactLastName = rd.contactLastName ?? ""
        contactEmail = rd.contactEmail ?? ""
        contactPhone = rd.contactPhone ?? ""
        contactNotes = rd.notes ?? ""
        demoRequired = rd.demoAccountRequired ?? false
        demoName = rd.demoAccountName ?? ""
        demoPassword = rd.demoAccountPassword ?? ""
    }

    private func applyPendingValues() {
        if let pending = asc.pendingFormValues["review.ageRating"] {
            for (field, value) in pending {
                switch field {
                case "gambling": arGambling = value == "true"
                case "messagingAndChat": arMessaging = value == "true"
                case "unrestrictedWebAccess": arWebAccess = value == "true"
                case "userGeneratedContent": arUGC = value == "true"
                case "advertising": arAdvertising = value == "true"
                case "lootBox": arLootBox = value == "true"
                case "healthOrWellnessTopics": arHealth = value == "true"
                case "parentalControls": arParental = value == "true"
                case "ageAssurance": arAgeAssurance = value == "true"
                case "alcoholTobaccoOrDrugUseOrReferences": arAlcohol = value
                case "contests": arContests = value
                case "gamblingSimulated": arGamblingSim = value
                case "gunsOrOtherWeapons": arGuns = value
                case "horrorOrFearThemes": arHorror = value
                case "matureOrSuggestiveThemes": arMature = value
                case "medicalOrTreatmentInformation": arMedical = value
                case "profanityOrCrudeHumor": arProfanity = value
                case "sexualContentGraphicAndNudity": arSexGraphic = value
                case "sexualContentOrNudity": arSex = value
                case "violenceCartoonOrFantasy": arViolenceCartoon = value
                case "violenceRealistic": arViolenceRealistic = value
                case "violenceRealisticProlongedGraphicOrSadistic": arViolenceProlonged = value
                default: break
                }
            }
        }
        if let pending = asc.pendingFormValues["review.contact"] {
            for (field, value) in pending {
                switch field {
                case "contactFirstName": contactFirstName = value
                case "contactLastName": contactLastName = value
                case "contactEmail": contactEmail = value
                case "contactPhone": contactPhone = value
                case "notes": contactNotes = value
                case "demoAccountRequired": demoRequired = value == "true"
                case "demoAccountName": demoName = value
                case "demoAccountPassword": demoPassword = value
                default: break
                }
            }
        }
    }

    // MARK: - Save

    private func saveAgeRating() async {
        isSavingAgeRating = true
        let attrs: [String: Any] = [
            "gambling": arGambling,
            "messagingAndChat": arMessaging,
            "unrestrictedWebAccess": arWebAccess,
            "userGeneratedContent": arUGC,
            "advertising": arAdvertising,
            "lootBox": arLootBox,
            "healthOrWellnessTopics": arHealth,
            "parentalControls": arParental,
            "ageAssurance": arAgeAssurance,
            "alcoholTobaccoOrDrugUseOrReferences": arAlcohol,
            "contests": arContests,
            "gamblingSimulated": arGamblingSim,
            "gunsOrOtherWeapons": arGuns,
            "horrorOrFearThemes": arHorror,
            "matureOrSuggestiveThemes": arMature,
            "medicalOrTreatmentInformation": arMedical,
            "profanityOrCrudeHumor": arProfanity,
            "sexualContentGraphicAndNudity": arSexGraphic,
            "sexualContentOrNudity": arSex,
            "violenceCartoonOrFantasy": arViolenceCartoon,
            "violenceRealistic": arViolenceRealistic,
            "violenceRealisticProlongedGraphicOrSadistic": arViolenceProlonged,
        ]
        await asc.updateAgeRating(attrs)
        isSavingAgeRating = false
    }

    private func saveContact() async {
        isSavingContact = true
        var attrs: [String: Any] = [
            "contactFirstName": contactFirstName,
            "contactLastName": contactLastName,
            "contactEmail": contactEmail,
            "contactPhone": contactPhone,
            "demoAccountRequired": demoRequired,
        ]
        if !contactNotes.isEmpty { attrs["notes"] = contactNotes }
        if demoRequired {
            attrs["demoAccountName"] = demoName
            attrs["demoAccountPassword"] = demoPassword
        }
        await asc.updateReviewContact(attrs)
        isSavingContact = false
    }

    // MARK: - UI Helpers

    private func stateBadge(_ state: String) -> some View {
        let (label, color) = stateColor(state)
        return Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func stateColor(_ state: String) -> (String, Color) {
        switch state {
        case "READY_FOR_SALE": return ("Live", .green)
        case "PROCESSING": return ("Processing", .orange)
        case "PENDING_DEVELOPER_RELEASE": return ("Pending Release", .yellow)
        case "IN_REVIEW": return ("In Review", .blue)
        case "WAITING_FOR_REVIEW": return ("Waiting", .blue)
        case "INVALID_BINARY": return ("Submission Error", .red)
        case "REJECTED": return ("Rejected", .red)
        case "DEVELOPER_REJECTED": return ("Dev Rejected", .orange)
        case "PREPARE_FOR_SUBMISSION": return ("Draft", .secondary)
        default:
            return (state.replacingOccurrences(of: "_", with: " ").capitalized, .secondary)
        }
    }

    /// Check if a version was previously rejected (has rejected submission items or cached feedback)
    private func wasVersionPreviouslyRejected(_ version: ASCAppStoreVersion) -> Bool {
        // If we have rejected submission items, the latest review was a rejection
        if asc.latestSubmissionItems.contains(where: { $0.attributes.state == "REJECTED" }) {
            return true
        }
        if asc.hasIrisFeedback(forVersionString: version.attributes.versionString) {
            return true
        }
        return false
    }

    private func syncSelectedBuild() {
        if !selectedBuild.isEmpty,
           asc.builds.contains(where: { $0.id == selectedBuild }) {
            return
        }
        selectedBuild = asc.builds.first(where: { $0.attributes.processingState == "VALID" })?.id
            ?? asc.builds.first?.id
            ?? ""
    }

}

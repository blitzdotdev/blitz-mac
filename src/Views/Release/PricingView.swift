import SwiftUI
import UniformTypeIdentifiers

struct MonetizationView: View {
    var appState: AppState

    private var asc: ASCManager { appState.ascManager }

    var body: some View {
        ASCCredentialGate(
            ascManager: asc,
            projectId: appState.activeProjectId ?? "",
            bundleId: appState.activeProject?.metadata.bundleIdentifier
        ) {
            ASCTabContent(asc: asc, tab: .monetization) {
                monetizationContent
            }
        }
        .task { await asc.fetchTabData(.monetization) }
    }

    @ViewBuilder
    private var monetizationContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Monetization")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    RefreshButton(asc: asc)
                }

                if let err = asc.writeError {
                    Text(err)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                AppPricingSection(asc: asc)
                InAppPurchasesSection(asc: asc)
                SubscriptionsSection(asc: asc)
            }
            .padding(24)
        }
    }
}

// MARK: - Shared Price Picker

private struct PricePicker: View {
    let pricePoints: [ASCPricePoint]
    @Binding var selectedPointId: String

    private var sortedPaidPoints: [ASCPricePoint] {
        pricePoints
            .filter { Double($0.attributes.customerPrice ?? "0") ?? 0 > 0 }
            .sorted { (Double($0.attributes.customerPrice ?? "0") ?? 0) < (Double($1.attributes.customerPrice ?? "0") ?? 0) }
    }

    var body: some View {
        Picker("Price", selection: $selectedPointId) {
            Text("Select a price…").tag("")
            ForEach(sortedPaidPoints) { pt in
                Text("$\(pt.attributes.customerPrice ?? "?")").tag(pt.id)
            }
        }
    }
}

// MARK: - Screenshot Picker

private struct ScreenshotPicker: View {
    let label: String
    @Binding var path: String
    @State private var showPicker = false

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            if path.isEmpty {
                Button("Choose File…") { showPicker = true }
                    .controlSize(.small)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.caption)
                        .lineLimit(1)
                    Button("Change") { showPicker = true }
                        .controlSize(.mini)
                }
            }
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.png, .jpeg]) { result in
            if case .success(let url) = result {
                path = url.path
            }
        }
    }
}

// MARK: - Create Progress Bar

private struct CreateProgressBar: View {
    let progress: Double
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            ProgressView(value: progress)
                .progressViewStyle(.linear)
        }
    }
}

// MARK: - Section Card

private struct SectionCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content()
        }
        .padding(16)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Section 1: App Pricing

private struct AppPricingSection: View {
    var asc: ASCManager
    @State private var isFree = true
    @State private var selectedPricePointId = ""
    @State private var isSaving = false
    @State private var showScheduled = false
    @State private var scheduledDate = Date().addingTimeInterval(86400 * 7)
    @State private var scheduledPricePointId = ""

    var body: some View {
        SectionCard {
            Label("Pricing & Availability", systemImage: "dollarsign.circle")
                .font(.headline)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Free App").font(.body.weight(.medium))
                    Text("Your app will be available for free on the App Store.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $isFree)
                    .labelsHidden()
                    .onChange(of: isFree) { _, newValue in
                        if newValue {
                            isSaving = true
                            selectedPricePointId = ""
                            Task {
                                await asc.setPriceFree()
                                isSaving = false
                            }
                        }
                    }
            }

            if !isFree {
                PricePicker(pricePoints: asc.appPricePoints, selectedPointId: $selectedPricePointId)

                if !selectedPricePointId.isEmpty {
                    Button("Set Price") {
                        isSaving = true
                        Task {
                            await asc.setAppPrice(pricePointId: selectedPricePointId)
                            isSaving = false
                        }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }

                Divider()

                DisclosureGroup("Schedule Price Change", isExpanded: $showScheduled) {
                    VStack(alignment: .leading, spacing: 12) {
                        DatePicker("Effective Date", selection: $scheduledDate, in: Date()..., displayedComponents: .date)
                        PricePicker(pricePoints: asc.appPricePoints, selectedPointId: $scheduledPricePointId)

                        if !scheduledPricePointId.isEmpty {
                            Button("Create Price Change") {
                                isSaving = true
                                let currentId = selectedPricePointId.isEmpty ? freePointId : selectedPricePointId
                                let dateStr = formatDate(scheduledDate)
                                Task {
                                    await asc.setScheduledAppPrice(
                                        currentPricePointId: currentId,
                                        futurePricePointId: scheduledPricePointId,
                                        effectiveDate: dateStr
                                    )
                                    isSaving = false
                                }
                            }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                        }
                    }
                    .padding(.top, 8)
                }
            }

            if isSaving {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Saving…").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var freePointId: String {
        asc.appPricePoints.first(where: {
            let p = $0.attributes.customerPrice ?? "0"
            return p == "0" || p == "0.0" || p == "0.00"
        })?.id ?? ""
    }

    private func formatDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }
}

// MARK: - Section 2: In-App Purchases

private struct InAppPurchasesSection: View {
    var asc: ASCManager
    @State private var showCreateForm = false
    @State private var expandedId: String?
    // Create form
    @State private var iapType = "CONSUMABLE"
    @State private var iapRefName = ""
    @State private var iapProductId = ""
    @State private var iapDisplayName = ""
    @State private var iapDescription = ""
    @State private var iapPricePointId = ""
    @State private var iapScreenshotPath = ""
    @State private var showValidation = false
    @State private var deleteTarget: ASCInAppPurchase?

    private let iapTypes = ["CONSUMABLE", "NON_CONSUMABLE", "NON_RENEWING_SUBSCRIPTION"]

    private var missingFields: [String] {
        var missing: [String] = []
        if iapRefName.isEmpty { missing.append("Reference Name") }
        if iapProductId.isEmpty { missing.append("Product ID") }
        if iapDisplayName.isEmpty { missing.append("Display Name") }
        if iapDescription.isEmpty { missing.append("Description") }
        if iapScreenshotPath.isEmpty { missing.append("Review Screenshot") }
        return missing
    }

    var body: some View {
        SectionCard {
            HStack {
                Label("In-App Purchases", systemImage: "cart")
                    .font(.headline)
                Spacer()
                Button(showCreateForm ? "Cancel" : "Create") {
                    showCreateForm.toggle()
                    if !showCreateForm { resetForm() }
                }
                .controlSize(.small)
            }

            if asc.inAppPurchases.isEmpty && !showCreateForm {
                Text("No in-app purchases configured.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(asc.inAppPurchases) { iap in
                    IAPDetailRow(
                        iap: iap, asc: asc,
                        isExpanded: expandedId == iap.id,
                        onToggle: { expandedId = expandedId == iap.id ? nil : iap.id },
                        onDelete: { deleteTarget = iap }
                    )
                }
            }

            if showCreateForm {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("New In-App Purchase").font(.subheadline.weight(.semibold))

                    Picker("Type", selection: $iapType) {
                        ForEach(iapTypes, id: \.self) { Text(formatType($0)).tag($0) }
                    }.pickerStyle(.segmented)

                    RequiredField("Reference Name", text: $iapRefName, showError: showValidation && iapRefName.isEmpty)
                    RequiredField("Product ID", text: $iapProductId, showError: showValidation && iapProductId.isEmpty)
                    RequiredField("Display Name", text: $iapDisplayName, showError: showValidation && iapDisplayName.isEmpty)
                    RequiredField("Description", text: $iapDescription, showError: showValidation && iapDescription.isEmpty)
                    PricePicker(pricePoints: asc.appPricePoints, selectedPointId: $iapPricePointId)
                    ScreenshotPicker(label: "Review Screenshot", path: $iapScreenshotPath)
                    if showValidation && iapScreenshotPath.isEmpty {
                        Text("Review screenshot is required.")
                            .font(.caption2).foregroundStyle(.red)
                    } else {
                        Text("Min 640x920px PNG/JPEG. Required by App Review.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }

                    if showValidation && !missingFields.isEmpty {
                        Text("Required: \(missingFields.joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.red)
                    }

                    if asc.isCreating {
                        CreateProgressBar(progress: asc.createProgress, message: asc.createProgressMessage)
                    } else {
                        Button("Create") {
                            if !missingFields.isEmpty {
                                showValidation = true
                                return
                            }
                            let price = priceForPointId(iapPricePointId)
                            asc.createIAP(
                                name: iapRefName, productId: iapProductId, type: iapType,
                                displayName: iapDisplayName,
                                description: iapDescription,
                                price: price, screenshotPath: iapScreenshotPath
                            )
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
            }
        }
        .onChange(of: asc.isCreating) { wasCreating, nowCreating in
            if wasCreating && !nowCreating && asc.writeError == nil {
                showCreateForm = false; resetForm()
            }
        }
        .alert("Delete In-App Purchase?", isPresented: .init(
            get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let t = deleteTarget { Task { await asc.deleteIAP(id: t.id) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete \"\(deleteTarget?.attributes.name ?? "")\".")
        }
        .onChange(of: asc.pendingCreateValues) { _, pending in
            guard let pending, pending["kind"] == "iap" else { return }
            showCreateForm = true
            if let v = pending["type"] { iapType = v }
            if let v = pending["name"] { iapRefName = v }
            if let v = pending["productId"] { iapProductId = v }
            if let v = pending["displayName"] { iapDisplayName = v }
            if let v = pending["description"] { iapDescription = v }
            asc.pendingCreateValues = nil
        }
    }

    private func resetForm() {
        iapType = "CONSUMABLE"; iapRefName = ""; iapProductId = ""
        iapDisplayName = ""; iapDescription = ""; iapPricePointId = ""
        iapScreenshotPath = ""; showValidation = false
    }

    private func priceForPointId(_ id: String) -> String {
        asc.appPricePoints.first(where: { $0.id == id })?.attributes.customerPrice ?? ""
    }
}

// MARK: - Required Field

private struct RequiredField: View {
    let placeholder: String
    @Binding var text: String
    let showError: Bool

    init(_ placeholder: String, text: Binding<String>, showError: Bool) {
        self.placeholder = placeholder
        self._text = text
        self.showError = showError
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(showError ? .red : .clear, lineWidth: 1)
                )
            if showError {
                Text("\(placeholder) is required.")
                    .font(.caption2).foregroundStyle(.red)
            }
        }
    }
}

// MARK: - IAP Expandable Row

private struct IAPDetailRow: View {
    let iap: ASCInAppPurchase
    var asc: ASCManager
    let isExpanded: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var editName: String = ""
    @State private var editDisplayName: String = ""
    @State private var editDescription: String = ""
    @State private var editReviewNote: String = ""
    @State private var screenshotPath: String = ""
    @State private var isSaving = false
    @State private var isUploading = false
    @State private var didLoadFields = false
    @State private var showValidation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack {
                Button(action: onToggle) {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(iap.attributes.name ?? "Unnamed").font(.body.weight(.medium))
                            HStack(spacing: 8) {
                                Text(iap.attributes.productId ?? "").font(.caption).foregroundStyle(.secondary)
                                Text(formatType(iap.attributes.inAppPurchaseType))
                                    .font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.blue.opacity(0.15)).clipShape(Capsule())
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                if iap.attributes.state == "READY_TO_SUBMIT" {
                    SubmitForReviewButton(
                        itemName: iap.attributes.name ?? "IAP",
                        asc: asc,
                        onSubmit: { await asc.submitIAPForReview(id: iap.id) }
                    )
                } else {
                    stateBadge(iap.attributes.state)
                }
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash").font(.caption)
                }.buttonStyle(.borderless)
            }
            .padding(.vertical, 6)

            // Expanded edit fields
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    RequiredField("Reference Name", text: $editName, showError: showValidation && editName.isEmpty)
                    RequiredField("Display Name", text: $editDisplayName, showError: showValidation && editDisplayName.isEmpty)
                    RequiredField("Description", text: $editDescription, showError: showValidation && editDescription.isEmpty)
                    TextField("Review Notes", text: $editReviewNote, axis: .vertical)
                        .lineLimit(2...4).textFieldStyle(.roundedBorder)

                    ScreenshotPicker(label: "Review Screenshot", path: $screenshotPath)
                    if !screenshotPath.isEmpty {
                        HStack {
                            Button("Upload Screenshot") {
                                isUploading = true
                                Task {
                                    await asc.uploadIAPScreenshot(iapId: iap.id, path: screenshotPath)
                                    isUploading = false
                                }
                            }
                            .controlSize(.small)
                            if isUploading { ProgressView().controlSize(.small) }
                        }
                    }

                    if showValidation && (editDisplayName.isEmpty || editDescription.isEmpty) {
                        Text("Display Name and Description are required.")
                            .font(.caption).foregroundStyle(.red)
                    }

                    HStack {
                        Button("Save") {
                            if editDisplayName.isEmpty || editDescription.isEmpty {
                                showValidation = true
                                return
                            }
                            isSaving = true
                            Task {
                                await asc.updateIAP(
                                    id: iap.id,
                                    name: editName.isEmpty ? nil : editName,
                                    reviewNote: editReviewNote,
                                    displayName: editDisplayName,
                                    description: editDescription
                                )
                                isSaving = false
                            }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(isSaving)
                        if isSaving { ProgressView().controlSize(.small) }
                    }
                }
                .padding(.leading, 20)
                .padding(.bottom, 8)
                .onAppear { loadFields() }
            }
        }
    }

    private func loadFields() {
        guard !didLoadFields else { return }
        didLoadFields = true
        editName = iap.attributes.name ?? ""
        editReviewNote = iap.attributes.reviewNote ?? ""
        editDisplayName = ""
        editDescription = ""
    }
}

// MARK: - Section 3: Subscriptions

private struct SubscriptionsSection: View {
    var asc: ASCManager
    @State private var showCreateForm = false
    @State private var expandedId: String?
    // Create form
    @State private var subGroupName = ""
    @State private var newGroupName = ""
    @State private var subRefName = ""
    @State private var subProductId = ""
    @State private var subDisplayName = ""
    @State private var subDescription = ""
    @State private var subDuration = "ONE_MONTH"
    @State private var subPricePointId = ""
    @State private var subScreenshotPath = ""
    @State private var showValidation = false
    @State private var deleteTarget: ASCSubscription?
    @State private var deleteGroupTarget: ASCSubscriptionGroup?

    private let durations = ["ONE_WEEK", "ONE_MONTH", "TWO_MONTHS", "THREE_MONTHS", "SIX_MONTHS", "ONE_YEAR"]

    private var effectiveGroupName: String {
        subGroupName.isEmpty ? newGroupName : subGroupName
    }

    private var missingFields: [String] {
        var missing: [String] = []
        if effectiveGroupName.isEmpty { missing.append("Group Name") }
        if subRefName.isEmpty { missing.append("Reference Name") }
        if subProductId.isEmpty { missing.append("Product ID") }
        if subDisplayName.isEmpty { missing.append("Display Name") }
        if subDescription.isEmpty { missing.append("Description") }
        if subScreenshotPath.isEmpty { missing.append("Review Screenshot") }
        return missing
    }

    var body: some View {
        SectionCard {
            HStack {
                Label("Subscriptions", systemImage: "arrow.triangle.2.circlepath")
                    .font(.headline)
                Spacer()
                Button(showCreateForm ? "Cancel" : "Create") {
                    showCreateForm.toggle()
                    if !showCreateForm { resetForm() }
                }
                .controlSize(.small)
            }

            if asc.subscriptionGroups.isEmpty && !showCreateForm {
                Text("No subscriptions configured.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(asc.subscriptionGroups) { group in
                    SubscriptionGroupRow(
                        group: group, asc: asc,
                        expandedId: $expandedId,
                        deleteTarget: $deleteTarget,
                        onDeleteGroup: { deleteGroupTarget = group }
                    )
                }
            }

            if showCreateForm {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("New Subscription").font(.subheadline.weight(.semibold))

                    if asc.subscriptionGroups.isEmpty {
                        RequiredField("Subscription Group Name", text: $newGroupName,
                                      showError: showValidation && effectiveGroupName.isEmpty)
                    } else {
                        Picker("Group", selection: $subGroupName) {
                            Text("New group…").tag("")
                            ForEach(asc.subscriptionGroups) { g in
                                Text(g.attributes.referenceName ?? g.id).tag(g.attributes.referenceName ?? g.id)
                            }
                        }
                        if subGroupName.isEmpty {
                            RequiredField("New Group Name", text: $newGroupName,
                                          showError: showValidation && effectiveGroupName.isEmpty)
                        }
                    }

                    RequiredField("Reference Name", text: $subRefName, showError: showValidation && subRefName.isEmpty)
                    RequiredField("Product ID", text: $subProductId, showError: showValidation && subProductId.isEmpty)
                    RequiredField("Display Name", text: $subDisplayName, showError: showValidation && subDisplayName.isEmpty)
                    RequiredField("Description", text: $subDescription, showError: showValidation && subDescription.isEmpty)

                    Picker("Duration", selection: $subDuration) {
                        ForEach(durations, id: \.self) { Text(formatDuration($0)).tag($0) }
                    }

                    PricePicker(pricePoints: asc.appPricePoints, selectedPointId: $subPricePointId)
                    ScreenshotPicker(label: "Review Screenshot", path: $subScreenshotPath)
                    if showValidation && subScreenshotPath.isEmpty {
                        Text("Review screenshot is required.")
                            .font(.caption2).foregroundStyle(.red)
                    } else {
                        Text("Min 640x920px PNG/JPEG. Required by App Review.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }

                    if showValidation && !missingFields.isEmpty {
                        Text("Required: \(missingFields.joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.red)
                    }

                    if asc.isCreating {
                        CreateProgressBar(progress: asc.createProgress, message: asc.createProgressMessage)
                    } else {
                        Button("Create") {
                            if !missingFields.isEmpty {
                                showValidation = true
                                return
                            }
                            let price = priceForPointId(subPricePointId)
                            asc.createSubscription(
                                groupName: effectiveGroupName, name: subRefName,
                                productId: subProductId, displayName: subDisplayName,
                                description: subDescription,
                                duration: subDuration, price: price, screenshotPath: subScreenshotPath
                            )
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
            }
        }
        .onChange(of: asc.isCreating) { wasCreating, nowCreating in
            if wasCreating && !nowCreating && asc.writeError == nil {
                showCreateForm = false; resetForm()
            }
        }
        .alert("Delete Subscription?", isPresented: .init(
            get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let t = deleteTarget { Task { await asc.deleteSubscription(id: t.id) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete \"\(deleteTarget?.attributes.name ?? "")\".")
        }
        .alert("Delete Subscription Group?", isPresented: .init(
            get: { deleteGroupTarget != nil }, set: { if !$0 { deleteGroupTarget = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let g = deleteGroupTarget { Task { await asc.deleteSubscriptionGroup(id: g.id) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the group \"\(deleteGroupTarget?.attributes.referenceName ?? "")\".")
        }
        .onChange(of: asc.pendingCreateValues) { _, pending in
            guard let pending, pending["kind"] == "subscription" else { return }
            showCreateForm = true
            if let v = pending["groupName"] { subGroupName = v; newGroupName = v }
            if let v = pending["name"] { subRefName = v }
            if let v = pending["productId"] { subProductId = v }
            if let v = pending["displayName"] { subDisplayName = v }
            if let v = pending["description"] { subDescription = v }
            if let v = pending["duration"] { subDuration = v }
            asc.pendingCreateValues = nil
        }
    }

    private func resetForm() {
        subGroupName = ""; newGroupName = ""; subRefName = ""; subProductId = ""
        subDisplayName = ""; subDescription = ""; subDuration = "ONE_MONTH"
        subPricePointId = ""; subScreenshotPath = ""; showValidation = false
    }

    private func priceForPointId(_ id: String) -> String {
        asc.appPricePoints.first(where: { $0.id == id })?.attributes.customerPrice ?? ""
    }
}

// MARK: - Subscription Group Row

private struct SubscriptionGroupRow: View {
    let group: ASCSubscriptionGroup
    var asc: ASCManager
    @Binding var expandedId: String?
    @Binding var deleteTarget: ASCSubscription?
    let onDeleteGroup: () -> Void
    @State private var editGroupName: String = ""
    @State private var isSavingGroup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(group.attributes.referenceName ?? "Group")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                let subs = asc.subscriptionsPerGroup[group.id] ?? []
                if subs.isEmpty {
                    Button(role: .destructive, action: onDeleteGroup) {
                        Image(systemName: "trash").font(.caption)
                    }.buttonStyle(.borderless)
                }
            }

            // Group localization edit
            HStack(spacing: 8) {
                TextField("Group Display Name", text: $editGroupName)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Button("Save") {
                    guard !editGroupName.isEmpty else { return }
                    isSavingGroup = true
                    Task {
                        await asc.updateSubscriptionGroupLocalization(groupId: group.id, name: editGroupName)
                        isSavingGroup = false
                    }
                }
                .controlSize(.mini)
                .disabled(editGroupName.isEmpty || isSavingGroup)
                if isSavingGroup { ProgressView().controlSize(.mini) }
            }

            let subs = asc.subscriptionsPerGroup[group.id] ?? []
            if subs.isEmpty {
                Text("No subscriptions in this group.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(subs) { sub in
                SubscriptionDetailRow(
                    sub: sub, asc: asc,
                    isExpanded: expandedId == sub.id,
                    onToggle: { expandedId = expandedId == sub.id ? nil : sub.id },
                    onDelete: { deleteTarget = sub }
                )
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            if editGroupName.isEmpty {
                editGroupName = group.attributes.referenceName ?? ""
            }
        }
    }
}

// MARK: - Subscription Expandable Row

private struct SubscriptionDetailRow: View {
    let sub: ASCSubscription
    var asc: ASCManager
    let isExpanded: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var editName: String = ""
    @State private var editDisplayName: String = ""
    @State private var editDescription: String = ""
    @State private var editReviewNote: String = ""
    @State private var screenshotPath: String = ""
    @State private var isSaving = false
    @State private var isUploading = false
    @State private var didLoadFields = false
    @State private var showValidation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onToggle) {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sub.attributes.name ?? "Unnamed").font(.body.weight(.medium))
                            HStack(spacing: 8) {
                                Text(sub.attributes.productId ?? "").font(.caption).foregroundStyle(.secondary)
                                Text(formatDuration(sub.attributes.subscriptionPeriod))
                                    .font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.purple.opacity(0.15)).clipShape(Capsule())
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                if sub.attributes.state == "READY_TO_SUBMIT" {
                    SubmitForReviewButton(
                        itemName: sub.attributes.name ?? "Subscription",
                        asc: asc,
                        onSubmit: { await asc.submitSubscriptionForReview(id: sub.id) }
                    )
                } else {
                    stateBadge(sub.attributes.state)
                }
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash").font(.caption)
                }.buttonStyle(.borderless)
            }
            .padding(.vertical, 6)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    RequiredField("Reference Name", text: $editName, showError: showValidation && editName.isEmpty)
                    RequiredField("Display Name", text: $editDisplayName, showError: showValidation && editDisplayName.isEmpty)
                    RequiredField("Description", text: $editDescription, showError: showValidation && editDescription.isEmpty)
                    TextField("Review Notes", text: $editReviewNote, axis: .vertical)
                        .lineLimit(2...4).textFieldStyle(.roundedBorder)

                    ScreenshotPicker(label: "Review Screenshot", path: $screenshotPath)
                    if !screenshotPath.isEmpty {
                        HStack {
                            Button("Upload Screenshot") {
                                isUploading = true
                                Task {
                                    await asc.uploadSubscriptionScreenshot(subscriptionId: sub.id, path: screenshotPath)
                                    isUploading = false
                                }
                            }
                            .controlSize(.small)
                            if isUploading { ProgressView().controlSize(.small) }
                        }
                    }

                    if showValidation && (editDisplayName.isEmpty || editDescription.isEmpty) {
                        Text("Display Name and Description are required.")
                            .font(.caption).foregroundStyle(.red)
                    }

                    HStack {
                        Button("Save") {
                            if editDisplayName.isEmpty || editDescription.isEmpty {
                                showValidation = true
                                return
                            }
                            isSaving = true
                            Task {
                                await asc.updateSubscription(
                                    id: sub.id,
                                    name: editName.isEmpty ? nil : editName,
                                    reviewNote: editReviewNote,
                                    displayName: editDisplayName,
                                    description: editDescription
                                )
                                isSaving = false
                            }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(isSaving)
                        if isSaving { ProgressView().controlSize(.small) }
                    }
                }
                .padding(.leading, 20)
                .padding(.bottom, 8)
                .onAppear { loadFields() }
            }
        }
    }

    private func loadFields() {
        guard !didLoadFields else { return }
        didLoadFields = true
        editName = sub.attributes.name ?? ""
        editReviewNote = sub.attributes.reviewNote ?? ""
        editDisplayName = ""
        editDescription = ""
    }
}

// MARK: - Refresh Button

private struct RefreshButton: View {
    var asc: ASCManager
    @State private var isRefreshing = false

    var body: some View {
        Button {
            isRefreshing = true
            Task {
                await asc.refreshMonetization()
                isRefreshing = false
            }
        } label: {
            if isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(.borderless)
        .disabled(isRefreshing)
        .help("Refresh IAP & subscription states")
    }
}

// MARK: - Submit Button

private struct SubmitForReviewButton: View {
    let itemName: String
    let asc: ASCManager
    let onSubmit: () async -> Bool

    @State private var showConfirm = false
    @State private var isSubmitting = false
    @State private var showFirstTimeAlert = false

    private var ascVersionURL: URL? {
        guard let appId = asc.app?.id else { return nil }
        return URL(string: "https://appstoreconnect.apple.com/apps/\(appId)/appstore")
    }

    var body: some View {
        Button("Submit for Review") {
            showConfirm = true
        }
        .controlSize(.mini)
        .buttonStyle(.borderedProminent)
        .tint(.green)
        .disabled(isSubmitting)
        .alert("Submit for Review?", isPresented: $showConfirm) {
            Button("Submit") {
                isSubmitting = true
                Task {
                    let success = await onSubmit()
                    isSubmitting = false
                    if !success, let err = asc.writeError, err.hasPrefix("FIRST_SUBMISSION:") {
                        asc.writeError = nil
                        showFirstTimeAlert = true
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Submit \"\(itemName)\" for App Review? This cannot be undone.")
        }
        .alert("First-Time Submission", isPresented: $showFirstTimeAlert) {
            if let url = ascVersionURL {
                Button("Open App Store Connect") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Apple requires the first IAP/Subscription to be submitted with an app version via the App Store Connect website.\n\nIn App Store Connect website: go to your app version, scroll to \"In-App Purchases and Subscriptions\", click \"Select In-App Purchases or Subscriptions\", check the items to include, then submit the version for review.\n\nAfter the first approval, future submissions can be done directly from Blitz.")
        }
        .overlay {
            if isSubmitting {
                ProgressView().controlSize(.mini)
            }
        }
    }
}

// MARK: - Helpers

private func formatType(_ type: String?) -> String {
    switch type {
    case "CONSUMABLE": return "Consumable"
    case "NON_CONSUMABLE": return "Non-Consumable"
    case "NON_RENEWING_SUBSCRIPTION": return "Non-Renewing"
    default: return type ?? ""
    }
}

private func formatDuration(_ d: String?) -> String {
    switch d {
    case "ONE_WEEK": return "1 Week"
    case "ONE_MONTH": return "1 Month"
    case "TWO_MONTHS": return "2 Months"
    case "THREE_MONTHS": return "3 Months"
    case "SIX_MONTHS": return "6 Months"
    case "ONE_YEAR": return "1 Year"
    default: return d ?? ""
    }
}

@ViewBuilder
private func stateBadge(_ state: String?) -> some View {
    let color: Color = switch state {
    case "READY_TO_SUBMIT": .green
    case "MISSING_METADATA": .orange
    case "WAITING_FOR_REVIEW", "IN_REVIEW": .blue
    case "APPROVED": .green
    default: .secondary
    }
    Text(state ?? "")
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
}

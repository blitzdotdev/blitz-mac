import SwiftUI

/// Shared rejection feedback card used by both ASCOverview and ReviewView.
struct RejectionCardView<Footer: View>: View {
    var asc: ASCManager
    var version: ASCAppStoreVersion
    @ViewBuilder var footer: () -> Footer
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Clickable header region — toggles expansion
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expanded.toggle()
                }
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    reviewHistory
                    reviewItems
                    submittedReviewInfo
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Collapsible content
            if expanded {
                appleFeedbackSection
                footer()
            }
        }
        .padding(16)
        .background(Color.red.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.red.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
            Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Version \(version.attributes.versionString) Rejected")
                    .font(.headline)
                if let date = version.attributes.createdDate {
                    Text("Submitted \(ascShortDate(date))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    // MARK: - Review History

    @ViewBuilder
    private var reviewHistory: some View {
        if !asc.reviewSubmissions.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Review History")
                    .font(.callout.weight(.semibold))

                ForEach(asc.reviewSubmissions.prefix(5)) { submission in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(submissionStateColor(submission.attributes.state ?? ""))
                            .frame(width: 8, height: 8)
                        Text(submissionStateLabel(submission.attributes.state ?? ""))
                            .font(.callout)
                        Spacer()
                        if let date = submission.attributes.submittedDate {
                            Text(ascShortDate(date))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Review Items

    @ViewBuilder
    private var reviewItems: some View {
        let submissionItems = asc.latestSubmissionItems(forVersionId: version.id)

        if !submissionItems.isEmpty {
            let rejected = submissionItems.filter { $0.attributes.state == "REJECTED" }
            let accepted = submissionItems.filter { $0.attributes.state == "ACCEPTED" || $0.attributes.state == "APPROVED" }

            if !rejected.isEmpty || !accepted.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Review Items")
                        .font(.callout.weight(.semibold))

                    ForEach(submissionItems) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.attributes.state == "REJECTED" ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(item.attributes.state == "REJECTED" ? .red : .green)
                                .font(.caption)
                            Text(item.attributes.state?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Unknown")
                                .font(.callout)
                            if item.attributes.resolved == true {
                                Text("Resolved")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.15))
                                    .foregroundStyle(.green)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Submitted Review Info

    @ViewBuilder
    private var submittedReviewInfo: some View {
        if let rd = asc.reviewDetail {
            VStack(alignment: .leading, spacing: 6) {
                Text("Submitted Review Info")
                    .font(.callout.weight(.semibold))

                if let notes = rd.attributes.notes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your Notes to Apple")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(notes)
                            .font(.callout)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.background.tertiary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }

                if rd.attributes.demoAccountRequired == true {
                    HStack(spacing: 6) {
                        Image(systemName: "person.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Demo account: \(rd.attributes.demoAccountName ?? "—")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let contact = rd.attributes.contactEmail {
                    HStack(spacing: 6) {
                        Image(systemName: "envelope")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Contact: \(rd.attributes.contactFirstName ?? "") \(rd.attributes.contactLastName ?? "") (\(contact))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Apple's Feedback

    @ViewBuilder
    private var appleFeedbackSection: some View {
        let cycles = asc.feedbackCycles(forVersionString: version.attributes.versionString)

        Divider()

        VStack(alignment: .leading, spacing: 10) {
            Text("Apple's Feedback")
                .font(.callout.weight(.semibold))

            if asc.isLoadingIrisFeedback && cycles.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading feedback…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if !cycles.isEmpty {
                feedbackCyclesView(cycles)
            } else if let error = asc.irisFeedbackError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                signInPrompt
            } else {
                signInPrompt
            }
        }
    }

    @ViewBuilder
    private var signInPrompt: some View {
        switch asc.irisSessionState {
        case .noSession, .unknown:
            HStack(spacing: 10) {
                Image(systemName: "person.badge.key")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Sign in with your Apple ID to see Apple's detailed review feedback.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Sign In") { asc.showAppleIDLogin = true }
                    .buttonStyle(.bordered)
            }
            .padding(10)
            .background(.background.tertiary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        case .expired:
            HStack(spacing: 10) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.title3)
                    .foregroundStyle(.orange)
                Text("Apple ID session expired.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Sign In Again") { asc.showAppleIDLogin = true }
                    .buttonStyle(.bordered)
            }
            .padding(10)
            .background(.background.tertiary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        case .valid:
            Text("No rejection feedback found in the Resolution Center.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func feedbackCyclesView(_ cycles: [IrisFeedbackCycle]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(cycles) { cycle in
                feedbackCycleView(cycle)
            }
        }
    }

    @ViewBuilder
    private func feedbackCycleView(_ cycle: IrisFeedbackCycle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let submissionId = cycle.submissionId, !submissionId.isEmpty {
                    Text(submissionId)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Archived Thread")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(ascLongDate(cycle.occurredAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !cycle.reasons.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(cycle.reasons) { reason in
                        reasonCard(section: reason.section, description: reason.description, code: reason.code)
                    }
                }
            }
            if !cycle.messages.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reviewer Messages")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(cycle.messages) { msg in
                        messageCard(body: msg.body, date: msg.createdAt)
                    }
                }
            }
        }
        .padding(10)
        .background(.background.tertiary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Card Helpers

    private func reasonCard(section: String?, description: String?, code: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let section, !section.isEmpty {
                Text(section)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.red)
            }
            if let desc = description, !desc.isEmpty {
                Text(desc)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            if let code, !code.isEmpty {
                Text("Code: \(code)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.tertiary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func messageCard(body: String?, date: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let body, !body.isEmpty {
                Text(body)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            if let date {
                Text(ascLongDate(date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.tertiary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Submission State Helpers

    private func submissionStateColor(_ state: String) -> Color {
        switch state {
        case "COMPLETE": return .green
        case "IN_PROGRESS", "WAITING_FOR_REVIEW": return .blue
        case "CANCELING": return .orange
        default: return .secondary
        }
    }

    private func submissionStateLabel(_ state: String) -> String {
        switch state {
        case "COMPLETE": return "Review Complete"
        case "IN_PROGRESS": return "In Progress"
        case "WAITING_FOR_REVIEW": return "Waiting for Review"
        case "CANCELING": return "Canceling"
        default: return state.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

import SwiftUI

struct AppWallDetailView: View {
    let app: AppWallApp

    @State private var versions: [AppWallVersion] = []
    @State private var events: [AppWallEvent] = []
    @State private var feedbacks: [AppWallFeedback] = []
    @State private var isLoading = true
    @State private var loadError: String?

    // MARK: - Data Loading

    private func loadAll() async {
        isLoading = true
        loadError = nil
        do {
            async let v = AppWallService.shared.fetchVersions(appId: app.id)
            async let e = AppWallService.shared.fetchEvents(appId: app.id)
            async let f = AppWallService.shared.fetchFeedbacks(appId: app.id)
            (versions, events, feedbacks) = try await (v, e, f)
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                appHeader
                    .padding(24)

                Divider()

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(40)
                } else if let error = loadError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(24)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        versionsSection
                        Divider()
                        eventsSection
                        if !feedbacks.isEmpty {
                            Divider()
                            feedbacksSection
                        }
                    }
                }
            }
        }
        .frame(width: 560)
        .task { await loadAll() }
    }

    // MARK: - Header

    private var appHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            appIcon(size: 72)

            VStack(alignment: .leading, spacing: 6) {
                Text(app.name)
                    .font(.title2.weight(.bold))

                Text(app.bundleId)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if let category = app.primaryCategory {
                        categoryBadge(category)
                    }
                    if let version = app.latestVersion {
                        Text("v\(version)")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    if let state = app.currentState {
                        stateBadge(state)
                    }
                }
            }

            Spacer()
        }
    }

    @ViewBuilder
    private func appIcon(size: CGFloat) -> some View {
        if let urlStr = app.iconUrl, let url = URL(string: urlStr) {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.2237))
                } else {
                    iconPlaceholder(size: size)
                }
            }
        } else {
            iconPlaceholder(size: size)
        }
    }

    private func iconPlaceholder(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2237)
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: size, height: size)
            Image(systemName: "app")
                .font(.system(size: size * 0.4))
                .foregroundStyle(Color.accentColor.opacity(0.5))
        }
    }

    private func categoryBadge(_ category: String) -> some View {
        Text(category.replacingOccurrences(of: "_", with: " ").capitalized)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.1), in: Capsule())
            .foregroundStyle(Color.accentColor)
    }

    @ViewBuilder
    private func stateBadge(_ state: String) -> some View {
        switch state.uppercased() {
        case "READY_FOR_SALE":
            Label("Live", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case "WAITING_FOR_REVIEW", "IN_REVIEW":
            Label("In Review", systemImage: "clock.fill").foregroundStyle(.orange)
        case "REJECTED":
            Label("Rejected", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        default:
            Text(state.replacingOccurrences(of: "_", with: " ").capitalized).foregroundStyle(.secondary)
        }
    }

    // MARK: - Versions Section

    private var versionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Versions", icon: "doc.text", count: versions.count)

            if versions.isEmpty {
                emptyPlaceholder("No version data synced yet")
            } else {
                VStack(spacing: 8) {
                    ForEach(versions) { version in
                        versionRow(version)
                    }
                }
            }
        }
        .padding(24)
    }

    private func versionRow(_ version: AppWallVersion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("v\(version.versionString)")
                    .font(.callout.weight(.semibold))
                Text(version.platform)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let state = version.state {
                    stateBadge(state).font(.caption)
                }
            }

            if let desc = version.description, !desc.isEmpty {
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if let whatsNew = version.whatsNew, !whatsNew.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Text("What's New:")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(whatsNew)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(12)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Events Section

    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Submission History", icon: "clock.arrow.circlepath", count: events.count)

            if events.isEmpty {
                emptyPlaceholder("No submission events synced yet")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(events.enumerated()), id: \.element.id) { idx, event in
                        eventRow(event, isLast: idx == events.count - 1)
                    }
                }
            }
        }
        .padding(24)
    }

    private func eventRow(_ event: AppWallEvent, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Timeline dot + line
            VStack(spacing: 0) {
                Circle()
                    .fill(eventColor(event.eventType))
                    .frame(width: 10, height: 10)
                    .padding(.top, 5)
                if !isLast {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 10)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(eventLabel(event.eventType))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(eventColor(event.eventType))
                    Text("v\(event.versionString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatDate(event.occurredAt))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let notes = event.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let source = event.source {
                    Text(source)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.bottom, isLast ? 0 : 14)
        }
    }

    private func eventColor(_ type: String) -> Color {
        switch type {
        case "live", "accepted": return .green
        case "rejected": return .red
        case "inReview", "submitted": return .orange
        case "withdrawn", "removed": return .secondary
        default: return .blue
        }
    }

    private func eventLabel(_ type: String) -> String {
        switch type {
        case "submitted": return "Submitted"
        case "inReview": return "In Review"
        case "processing": return "Processing"
        case "accepted": return "Accepted"
        case "rejected": return "Rejected"
        case "withdrawn": return "Withdrawn"
        case "live": return "Live"
        case "removed": return "Removed"
        case "submissionError": return "Error"
        default: return type.capitalized
        }
    }

    // MARK: - Feedback Section

    private var feedbacksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Reviewer Feedback", icon: "bubble.left.and.bubble.right", count: feedbacks.count)

            VStack(spacing: 8) {
                ForEach(feedbacks) { feedback in
                    feedbackCard(feedback)
                }
            }
        }
        .padding(24)
    }

    private func feedbackCard(_ feedback: AppWallFeedback) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                feedbackTypeBadge(feedback.feedbackType)
                Text("v\(feedback.versionString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatDate(feedback.occurredAt))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            let guidelineIds = feedback.parsedGuidelineIds
            if !guidelineIds.isEmpty {
                HStack(spacing: 4) {
                    ForEach(guidelineIds, id: \.self) { gid in
                        Text(gid)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
            }

            if let msg = feedback.reviewerMessage, !msg.isEmpty {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let reasons = feedback.parsedRejectionReasons
            if !reasons.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(reasons, id: \.self) { reason in
                        HStack(alignment: .top, spacing: 4) {
                            Text("•").font(.caption).foregroundStyle(.secondary)
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func feedbackTypeBadge(_ type: String) -> some View {
        let (label, color): (String, Color) = switch type {
        case "rejection": ("Rejected", .red)
        case "metadata_rejection": ("Metadata", .orange)
        case "approval": ("Approved", .green)
        default: (type.capitalized, .secondary)
        }
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: - Shared helpers

    private func sectionHeader(_ title: String, icon: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            if count > 0 {
                Text("\(count)")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func emptyPlaceholder(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: iso) {
            let out = DateFormatter()
            out.dateStyle = .medium
            out.timeStyle = .none
            return out.string(from: date)
        }
        // Fallback: try without fractional seconds
        f.formatOptions = [.withInternetDateTime]
        if let date = f.date(from: iso) {
            let out = DateFormatter()
            out.dateStyle = .medium
            out.timeStyle = .none
            return out.string(from: date)
        }
        return String(iso.prefix(10))
    }


}

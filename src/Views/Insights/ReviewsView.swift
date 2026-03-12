import SwiftUI

struct ReviewsView: View {
    var appState: AppState

    private var asc: ASCManager { appState.ascManager }

    var body: some View {
        ASCCredentialGate(
            ascManager: asc,
            projectId: appState.activeProjectId ?? "",
            bundleId: appState.activeProject?.metadata.bundleIdentifier
        ) {
            ASCTabContent(asc: asc, tab: .reviews) {
                reviewsContent
            }
        }
        .task { await asc.fetchTabData(.reviews) }
    }

    @ViewBuilder
    private var reviewsContent: some View {
        if asc.customerReviews.isEmpty {
            ContentUnavailableView(
                "No Reviews",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("No customer reviews found for this app.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(asc.customerReviews) { review in
                reviewRow(review)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }
            .listStyle(.plain)
        }
    }

    private func reviewRow(_ review: ASCCustomerReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                starRating(review.attributes.rating)
                if let territory = review.attributes.territory {
                    Text(flagEmoji(territory))
                        .font(.callout)
                }
                Spacer()
                if let date = review.attributes.createdDate {
                    Text(ascShortDate(date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let title = review.attributes.title, !title.isEmpty {
                Text(title)
                    .font(.callout.weight(.semibold))
            }

            if let body = review.attributes.body, !body.isEmpty {
                Text(body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }

            HStack {
                if let nickname = review.attributes.reviewerNickname {
                    Text("by \(nickname)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if let appId = asc.app?.id {
                    Link(destination: URL(string: "https://appstoreconnect.apple.com/apps/\(appId)/appstore/ios/customerreviews")!) {
                        Text("Reply")
                            .font(.caption.weight(.medium))
                    }
                }
            }
        }
    }

    private func starRating(_ rating: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= rating ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundStyle(i <= rating ? .yellow : .secondary)
            }
        }
    }

    private func flagEmoji(_ territory: String) -> String {
        // Convert country code to flag emoji (regional indicator symbols)
        guard territory.count == 2 else { return "" }
        let base: UInt32 = 127397
        return territory.uppercased().unicodeScalars.compactMap {
            UnicodeScalar(base + $0.value)
        }.map { String($0) }.joined()
    }
}

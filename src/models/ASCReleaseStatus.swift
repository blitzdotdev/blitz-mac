import Foundation

struct ASCDashboardProjectStatus: Codable, Sendable, Equatable {
    let isLiveOnStore: Bool
    let isPendingReview: Bool
    let isRejected: Bool

    init(isLiveOnStore: Bool, isPendingReview: Bool, isRejected: Bool) {
        self.isLiveOnStore = isLiveOnStore
        self.isPendingReview = isPendingReview
        self.isRejected = isRejected
    }

    static let empty = ASCDashboardProjectStatus(
        isLiveOnStore: false,
        isPendingReview: false,
        isRejected: false
    )

    init(versions: [ASCAppStoreVersion]) {
        let sortedVersions = ASCReleaseStatus.sortedVersionsByRecency(versions)
        let liveIndex = sortedVersions.firstIndex {
            ASCReleaseStatus.liveStates.contains(
                ASCReleaseStatus.normalize($0.attributes.appStoreState)
            )
        }
        let actionableIndex = sortedVersions.firstIndex { version in
            let state = ASCReleaseStatus.normalize(version.attributes.appStoreState)
            return ASCReleaseStatus.pendingReviewStates.contains(state)
                || ASCReleaseStatus.rejectedStates.contains(state)
        }

        isLiveOnStore = liveIndex != nil

        guard let actionableIndex else {
            isPendingReview = false
            isRejected = false
            return
        }

        let actionableState = ASCReleaseStatus.normalize(
            sortedVersions[actionableIndex].attributes.appStoreState
        )
        let actionableStateIsCurrent = liveIndex == nil || actionableIndex < liveIndex!

        isPendingReview = actionableStateIsCurrent
            && ASCReleaseStatus.pendingReviewStates.contains(actionableState)
        isRejected = actionableStateIsCurrent
            && ASCReleaseStatus.rejectedStates.contains(actionableState)
    }
}

struct ASCDashboardSummary: Codable, Sendable, Equatable {
    var liveCount: Int
    var pendingCount: Int
    var rejectedCount: Int

    static let empty = ASCDashboardSummary(liveCount: 0, pendingCount: 0, rejectedCount: 0)

    mutating func include(_ projectStatus: ASCDashboardProjectStatus) {
        if projectStatus.isLiveOnStore {
            liveCount += 1
        }
        if projectStatus.isPendingReview {
            pendingCount += 1
        }
        if projectStatus.isRejected {
            rejectedCount += 1
        }
    }
}

enum ASCReleaseStatus {
    static let liveStates: Set<String> = [ "READY_FOR_SALE" ]

    static let removedStates: Set<String> = [
        "REMOVED_FROM_SALE",
        "DEVELOPER_REMOVED_FROM_SALE",
    ]

    static let pendingReviewStates: Set<String> = [
        "ACCEPTED",
        "IN_REVIEW",
        "PENDING_APPLE_RELEASE",
        "PENDING_DEVELOPER_RELEASE",
        "PROCESSING",
        "PROCESSING_FOR_APP_STORE",
        "PROCESSING_FOR_DISTRIBUTION",
        "WAITING_FOR_REVIEW",
    ]

    static let rejectedStates: Set<String> = [
        "INVALID_BINARY",
        "METADATA_REJECTED",
        "REJECTED",
    ]

    static let editableStates: Set<String> = Set([
        "DEVELOPER_REJECTED",
        "PREPARE_FOR_SUBMISSION",
    ]).union(rejectedStates)

    static let lockedStates: Set<String> = liveStates.union(removedStates).union(pendingReviewStates)

    static func submissionHistoryEventType(forVersionState state: String?) -> ASCSubmissionHistoryEventType? {
        switch normalize(state) {
        case "WAITING_FOR_REVIEW":
            return .submitted
        case "IN_REVIEW":
            return .inReview
        case "PROCESSING", "PROCESSING_FOR_APP_STORE", "PROCESSING_FOR_DISTRIBUTION":
            return .processing
        case "ACCEPTED", "PENDING_DEVELOPER_RELEASE":
            return .accepted
        case "READY_FOR_SALE":
            return .live
        case "INVALID_BINARY":
            return .submissionError
        case "METADATA_REJECTED", "REJECTED":
            return .rejected
        case "DEVELOPER_REJECTED":
            return .withdrawn
        case "REMOVED_FROM_SALE", "DEVELOPER_REMOVED_FROM_SALE":
            return .removed
        default:
            return nil
        }
    }

    static func reviewSubmissionEventType(forVersionState state: String?) -> ASCSubmissionHistoryEventType {
        if normalize(state) == "INVALID_BINARY" {
            return .submissionError
        }
        return .submitted
    }

    static func isLive(_ state: String?) -> Bool {
        liveStates.contains(normalize(state))
    }

    static func isRemoved(_ state: String?) -> Bool {
        removedStates.contains(normalize(state))
    }

    static func isLocked(_ state: String?) -> Bool {
        lockedStates.contains(normalize(state))
    }

    static func isEditable(_ state: String?) -> Bool {
        let normalized = normalize(state)
        guard !normalized.isEmpty else { return false }
        if editableStates.contains(normalized) {
            return true
        }
        return !isLocked(normalized)
    }

    static func isCurrentUpdateCandidate(_ state: String?) -> Bool {
        let normalized = normalize(state)
        return !normalized.isEmpty && !isLive(normalized) && !isRemoved(normalized)
    }

    static func normalize(_ state: String?) -> String {
        state?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
    }

    static func sortedVersionsByRecency(_ versions: [ASCAppStoreVersion]) -> [ASCAppStoreVersion] {
        versions.sorted { lhs, rhs in
            let dateComparison = compareDates(lhs.attributes.createdDate, rhs.attributes.createdDate)
            if dateComparison != 0 {
                return dateComparison > 0
            }
            return lhs.id > rhs.id
        }
    }

    static func currentLiveVersion(for versions: [ASCAppStoreVersion]) -> ASCAppStoreVersion? {
        let sortedVersions = sortedVersionsByRecency(versions)
        return sortedVersions.first { liveStates.contains(normalize($0.attributes.appStoreState)) }
    }

    static func currentUpdateVersion(for versions: [ASCAppStoreVersion]) -> ASCAppStoreVersion? {
        currentVersionWindow(for: versions).first { version in
            isCurrentUpdateCandidate(version.attributes.appStoreState)
        }
    }

    static func currentEditableVersion(for versions: [ASCAppStoreVersion]) -> ASCAppStoreVersion? {
        currentVersionWindow(for: versions).first { version in
            isEditable(version.attributes.appStoreState)
        }
    }

    static func defaultSelectedVersion(for versions: [ASCAppStoreVersion]) -> ASCAppStoreVersion? {
        let sortedVersions = sortedVersionsByRecency(versions)
        return currentUpdateVersion(for: sortedVersions)
            ?? currentEditableVersion(for: sortedVersions)
            ?? currentLiveVersion(for: sortedVersions)
            ?? sortedVersions.first
    }

    /// App Wall shows one compact version summary per app, so it should use the
    /// same "current" version that the dashboard summary logic would surface
    /// instead of blindly taking the newest row.
    static func appWallCurrentVersion(for versions: [ASCAppStoreVersion]) -> ASCAppStoreVersion? {
        let sortedVersions = sortedVersionsByRecency(versions)
        guard !sortedVersions.isEmpty else { return nil }

        let liveIndex = sortedVersions.firstIndex {
            liveStates.contains(normalize($0.attributes.appStoreState))
        }
        let actionableIndex = sortedVersions.firstIndex { version in
            let state = normalize(version.attributes.appStoreState)
            return pendingReviewStates.contains(state) || rejectedStates.contains(state)
        }

        if let actionableIndex {
            let actionableStateIsCurrent = liveIndex == nil || actionableIndex < liveIndex!
            if actionableStateIsCurrent {
                return sortedVersions[actionableIndex]
            }
        }

        if let liveIndex {
            return sortedVersions[liveIndex]
        }

        let newestVersion = sortedVersions[0]
        let newestState = normalize(newestVersion.attributes.appStoreState)
        return newestState.isEmpty ? nil : newestVersion
    }

    /// App Wall shows one compact state per app, so it should summarize the
    /// version set the same way the dashboard does instead of copying the newest
    /// version row verbatim. That keeps live apps live when a newer draft exists.
    static func appWallCurrentState(for versions: [ASCAppStoreVersion]) -> String? {
        normalize(appWallCurrentVersion(for: versions)?.attributes.appStoreState)
            .nilIfEmpty
    }

    private static func currentVersionWindow(for versions: [ASCAppStoreVersion]) -> ArraySlice<ASCAppStoreVersion> {
        let sortedVersions = sortedVersionsByRecency(versions)
        guard let liveIndex = sortedVersions.firstIndex(where: {
            liveStates.contains(normalize($0.attributes.appStoreState))
        }) else {
            return sortedVersions[...]
        }

        if liveIndex == 0 {
            return []
        }

        return sortedVersions[..<liveIndex]
    }

    private static func compareDates(_ lhs: String?, _ rhs: String?) -> Int {
        let lhsDate = parseDate(lhs)
        let rhsDate = parseDate(rhs)

        switch (lhsDate, rhsDate) {
        case let (.some(lhsDate), .some(rhsDate)):
            if lhsDate > rhsDate { return 1 }
            if lhsDate < rhsDate { return -1 }
            return 0
        case (.some, .none):
            return 1
        case (.none, .some):
            return -1
        case (.none, .none):
            let lhsValue = lhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rhsValue = rhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if lhsValue > rhsValue { return 1 }
            if lhsValue < rhsValue { return -1 }
            return 0
        }
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractionalFormatter.date(from: trimmed) {
            return parsed
        }

        let formatter = ISO8601DateFormatter()
        return formatter.date(from: trimmed)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

import CryptoKit
import Foundation

struct IrisFeedbackProjection: Codable {
    let appId: String
    let cycles: [IrisFeedbackCycle]
    let lastRebuiltAt: String
}

struct IrisFeedbackCycle: Codable, Identifiable {
    struct Message: Codable, Identifiable {
        let id: String
        let body: String
        let createdAt: String?
    }

    struct Reason: Codable, Identifiable {
        let id: String
        let section: String
        let description: String
        let code: String
    }

    let id: String
    var versionString: String?
    var submissionId: String?
    var occurredAt: String
    var threadCreatedAt: String?
    var lastMessageAt: String?
    var messages: [Message]
    var reasons: [Reason]
    var source: String
    var blobHashes: [String]

    var reviewerMessage: String? {
        let bodies = messages.map(\.body).map(trimmed).filter { !$0.isEmpty }
        guard !bodies.isEmpty else { return nil }
        return bodies.joined(separator: "\n\n")
    }

    var guidelineIds: [String] {
        Array(Set(reasons.map(\.code).map(trimmed).filter { !$0.isEmpty })).sorted()
    }

    var primaryReasonSection: String? {
        reasons.map(\.section).map(trimmed).first { !$0.isEmpty }
    }

    // A thread is the stable identity for one App Review feedback cycle.
    static func empty(id: String, occurredAt: String? = nil) -> Self {
        IrisFeedbackCycle(
            id: id,
            versionString: nil,
            submissionId: nil,
            occurredAt: occurredAt ?? irisArchiveNowString(),
            threadCreatedAt: nil,
            lastMessageAt: nil,
            messages: [],
            reasons: [],
            source: "archive",
            blobHashes: []
        )
    }
}

enum IrisArchiveStore {
    // Store the exact server payload once by content hash. The manifest is the
    // only place that tracks when and from which endpoint scope we saw that blob.
    static func recordRawResponse(appId: String, scopeKey: String, data: Data) throws {
        let appDir = archiveDirectory(appId: appId)
        let blobsDir = appDir.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)

        let blobHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let blobURL = rawBlobURL(appId: appId, blobHash: blobHash)
        if !FileManager.default.fileExists(atPath: blobURL.path) {
            try data.write(to: blobURL, options: .atomic)
        }

        var manifest = loadManifest(appId: appId)
        let now = irisArchiveNowString()
        if let index = manifest.entries.firstIndex(where: { $0.scopeKey == scopeKey && $0.blobHash == blobHash }) {
            manifest.entries[index].lastSeenAt = now
            manifest.entries[index].seenCount += 1
        } else {
            manifest.entries.append(
                .init(
                    scopeKey: scopeKey,
                    blobHash: blobHash,
                    firstSeenAt: now,
                    lastSeenAt: now,
                    seenCount: 1
                )
            )
        }
        try saveManifest(manifest, appId: appId)
    }

    static func loadProjection(appId: String) -> IrisFeedbackProjection? {
        let projectionURL = projectionURL(appId: appId)
        if let data = try? Data(contentsOf: projectionURL),
           let projection = try? JSONDecoder().decode(IrisFeedbackProjection.self, from: data) {
            return projection
        }

        let manifest = loadManifest(appId: appId)
        if !manifest.entries.isEmpty {
            return try? rebuildProjection(appId: appId)
        }

        return nil
    }

    @discardableResult
    static func rebuildProjection(appId: String) throws -> IrisFeedbackProjection {
        let manifest = loadManifest(appId: appId)
        guard !manifest.entries.isEmpty else {
            let projection = IrisFeedbackProjection(appId: appId, cycles: [], lastRebuiltAt: irisArchiveNowString())
            try saveProjection(projection, appId: appId)
            return projection
        }

        var cyclesByThreadId: [String: IrisFeedbackCycle] = [:]
        for entry in manifest.entries {
            guard let data = try? Data(contentsOf: rawBlobURL(appId: appId, blobHash: entry.blobHash)) else { continue }

            // Projection is rebuilt from raw blobs, not incrementally mutated on fetch.
            // That keeps the archive canonical and the derived view disposable.
            if URL(string: entry.scopeKey)?.path.hasSuffix("/resolutionCenterThreads") == true {
                let threads = (try? JSONDecoder().decode(IrisThreadPage.self, from: data).data) ?? []
                for thread in threads {
                    var cycle = cyclesByThreadId[thread.id] ?? .empty(
                        id: thread.id,
                        occurredAt: thread.attributes.createdDate
                    )
                    if !cycle.blobHashes.contains(entry.blobHash) {
                        cycle.blobHashes.append(entry.blobHash)
                    }
                    if let createdDate = thread.attributes.createdDate {
                        cycle.threadCreatedAt = createdDate
                        cycle.occurredAt = createdDate
                    }
                    if irisArchiveSortDate(thread.attributes.lastMessageResponseDate) > irisArchiveSortDate(cycle.lastMessageAt) {
                        cycle.lastMessageAt = thread.attributes.lastMessageResponseDate
                    }
                    cyclesByThreadId[thread.id] = cycle
                }
                continue
            }

            guard let threadId = threadId(forScopeKey: entry.scopeKey) else { continue }
            let page = try? JSONDecoder().decode(IrisMessagePage.self, from: data)
            var cycle = cyclesByThreadId[threadId] ?? .empty(id: threadId)
            if !cycle.blobHashes.contains(entry.blobHash) {
                cycle.blobHashes.append(entry.blobHash)
            }

            for message in page?.data ?? [] {
                // Message ids are stable. If we see the same id again, prefer the
                // richer body and otherwise the newest copy.
                let incoming = IrisFeedbackCycle.Message(
                    id: message.id,
                    body: trimmed(htmlToPlainText(message.attributes.messageBody ?? "")),
                    createdAt: message.attributes.createdDate
                )
                if let index = cycle.messages.firstIndex(where: { $0.id == incoming.id }) {
                    let existing = cycle.messages[index]
                    if trimmed(existing.body).isEmpty && !trimmed(incoming.body).isEmpty {
                        cycle.messages[index] = incoming
                    } else if irisArchiveSortDate(incoming.createdAt) >= irisArchiveSortDate(existing.createdAt) {
                        cycle.messages[index] = incoming
                    }
                } else {
                    cycle.messages.append(incoming)
                }
            }
            cycle.messages.sort {
                irisArchiveSortDate($0.createdAt) < irisArchiveSortDate($1.createdAt)
            }

            let included = (page?.included ?? []).filter { $0.type == "reviewRejections" }
            for item in included {
                guard let itemData = try? JSONEncoder().encode(item),
                      let rejection = try? JSONDecoder().decode(IrisReviewRejection.self, from: itemData) else {
                    continue
                }
                for (index, reason) in (rejection.attributes.reasons ?? []).enumerated() {
                    // Rejection ids can contain multiple reasons, so reason identity is
                    // "<rejection id>:<reason index>".
                    let incoming = IrisFeedbackCycle.Reason(
                        id: "\(rejection.id):\(index)",
                        section: trimmed(reason.reasonSection),
                        description: trimmed(reason.reasonDescription),
                        code: trimmed(reason.reasonCode)
                    )
                    if let existingIndex = cycle.reasons.firstIndex(where: { $0.id == incoming.id }) {
                        cycle.reasons[existingIndex] = incoming
                    } else {
                        cycle.reasons.append(incoming)
                    }
                }
            }
            cycle.reasons.sort { $0.id < $1.id }

            let messageBodies = cycle.messages.map(\.body)
            // Iris does not expose these as structured top-level fields on the thread,
            // so we recover them from the reviewer message text.
            cycle.versionString = firstMatch(in: messageBodies, label: "Version reviewed")
            cycle.submissionId = firstMatch(in: messageBodies, label: "Submission ID")
            if cycle.threadCreatedAt == nil,
               let earliestMessageAt = cycle.messages.compactMap(\.createdAt).min(by: { irisArchiveSortDate($0) < irisArchiveSortDate($1) }) {
                cycle.occurredAt = earliestMessageAt
            }
            if let latestMessageAt = cycle.messages.compactMap(\.createdAt).max(by: { irisArchiveSortDate($0) < irisArchiveSortDate($1) }),
               irisArchiveSortDate(latestMessageAt) > irisArchiveSortDate(cycle.lastMessageAt) {
                cycle.lastMessageAt = latestMessageAt
            }
            cyclesByThreadId[threadId] = cycle
        }

        let cycles = cyclesByThreadId.values
            .filter { !$0.messages.isEmpty || !$0.reasons.isEmpty || $0.versionString != nil || $0.submissionId != nil }
            .map { cycle in
                var cycle = cycle
                cycle.blobHashes.sort()
                return cycle
            }
            .sorted { irisArchiveSortDate($0.occurredAt) > irisArchiveSortDate($1.occurredAt) }

        let projection = IrisFeedbackProjection(
            appId: appId,
            cycles: cycles,
            lastRebuiltAt: irisArchiveNowString()
        )
        try saveProjection(projection, appId: appId)
        return projection
    }

    private struct IrisArchiveManifest: Codable {
        let appId: String
        var entries: [Entry]

        struct Entry: Codable {
            let scopeKey: String
            let blobHash: String
            var firstSeenAt: String
            var lastSeenAt: String
            var seenCount: Int
        }
    }

    private struct IrisMessagePage: Decodable {
        let data: [IrisResolutionCenterMessage]
        let included: [IrisIncludedItem]?
    }

    private struct IrisThreadPage: Decodable {
        let data: [Thread]

        struct Thread: Decodable {
            let id: String
            let attributes: Attributes

            struct Attributes: Decodable {
                let createdDate: String?
                let lastMessageResponseDate: String?
            }
        }
    }

    // Apple embeds fields like "Submission ID: ..." inside the message body.
    private static func firstMatch(in texts: [String], label: String) -> String? {
        for text in texts {
            for line in text.split(whereSeparator: \.isNewline) {
                let stringLine = String(line)
                guard let range = stringLine.range(of: "\(label):", options: [.caseInsensitive]) else { continue }
                let value = trimmed(String(stringLine[range.upperBound...]))
                if !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private static func saveProjection(_ projection: IrisFeedbackProjection, appId: String) throws {
        let url = projectionURL(appId: appId)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(projection).write(to: url, options: .atomic)
    }

    private static func loadManifest(appId: String) -> IrisArchiveManifest {
        let url = manifestURL(appId: appId)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(IrisArchiveManifest.self, from: data) else {
            return IrisArchiveManifest(appId: appId, entries: [])
        }
        return manifest
    }

    private static func saveManifest(_ manifest: IrisArchiveManifest, appId: String) throws {
        let url = manifestURL(appId: appId)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    private static func archiveDirectory(appId: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".blitz/iris-cache-v2/\(appId)")
    }

    private static func rawBlobURL(appId: String, blobHash: String) -> URL {
        archiveDirectory(appId: appId).appendingPathComponent("blobs/\(blobHash).json")
    }

    private static func manifestURL(appId: String) -> URL {
        archiveDirectory(appId: appId).appendingPathComponent("manifest.json")
    }

    private static func projectionURL(appId: String) -> URL {
        archiveDirectory(appId: appId).appendingPathComponent("projection.json")
    }

    private static func threadId(forScopeKey scopeKey: String) -> String? {
        guard let components = URL(string: scopeKey)?.pathComponents,
              let index = components.firstIndex(of: "resolutionCenterThreads"),
              components.indices.contains(index + 2),
              components[index + 2] == "resolutionCenterMessages" else {
            return nil
        }
        return components[index + 1]
    }
}

func trimmed(_ string: String?) -> String {
    (string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

func irisArchiveNowString() -> String {
    ISO8601DateFormatter().string(from: Date())
}

func irisArchiveDate(_ iso: String?) -> Date? {
    guard let iso, !iso.isEmpty else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let basic = ISO8601DateFormatter()
    return fractional.date(from: iso) ?? basic.date(from: iso)
}

func irisArchiveSortDate(_ iso: String?) -> Date {
    irisArchiveDate(iso) ?? .distantPast
}

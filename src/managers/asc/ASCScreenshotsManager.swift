import Foundation
import AppKit
import ImageIO

// MARK: - Screenshots Manager
// Extension containing screenshot-related functionality for ASCManager

extension ASCManager {
    nonisolated private static let screenshotDimensionsByDisplayType: [String: [(width: Int, height: Int)]] = [
        "APP_IPHONE_67": [
            (1260, 2736), (1290, 2796), (1320, 2868),
            (2736, 1260), (2796, 1290), (2868, 1320),
        ],
        "APP_IPAD_PRO_3GEN_129": [
            (2048, 2732), (2064, 2752),
            (2732, 2048), (2752, 2064),
        ],
        "APP_DESKTOP": [
            (1280, 800), (1440, 900), (2560, 1600), (2880, 1800),
        ],
    ]

    private struct PreparedTrackUpload {
        let path: String
        let isTemporary: Bool
    }

    // MARK: - Screenshot Data

    func screenshotCacheKey(versionId: String? = nil, locale: String) -> String {
        let resolvedVersionId = versionId ?? selectedVersion?.id ?? "current"
        return "\(resolvedVersionId)::\(locale)"
    }

    func screenshotTrackKey(displayType: String, locale: String, versionId: String? = nil) -> String {
        "\(screenshotCacheKey(versionId: versionId, locale: locale))::\(displayType)"
    }

    func hasTrackState(displayType: String, locale: String = "en-US") -> Bool {
        trackSlots[screenshotTrackKey(displayType: displayType, locale: locale)] != nil
    }

    func trackSlotsForDisplayType(_ displayType: String, locale: String = "en-US") -> [TrackSlot?] {
        trackSlots[screenshotTrackKey(displayType: displayType, locale: locale)]
            ?? Array(repeating: nil, count: 10)
    }

    func savedTrackStateForDisplayType(_ displayType: String, locale: String = "en-US") -> [TrackSlot?] {
        savedTrackState[screenshotTrackKey(displayType: displayType, locale: locale)]
            ?? Array(repeating: nil, count: 10)
    }

    func loadScreenshots(locale: String, force: Bool = false) async {
        guard let service else { return }
        let cacheKey = screenshotCacheKey(locale: locale)

        if !force,
           screenshotSetsByLocale[cacheKey] != nil,
           let cachedScreenshots = screenshotsByLocale[cacheKey] {
            await hydrateScreenshotImageCache(
                screenshots: cachedScreenshots,
                force: false
            )
            return
        }

        await ensureScreenshotLocalizationsLoaded(service: service)
        guard let loc = localizations.first(where: { $0.attributes.locale == locale })
                ?? localizations.first else {
            return
        }

        do {
            let previousScreenshotIDs = screenshotIDs(in: screenshotsByLocale[cacheKey] ?? [:])
            let (fetchedSets, fetchedScreenshots) = try await fetchScreenshotData(
                localizationId: loc.id,
                service: service
            )
            updateScreenshotCache(locale: loc.attributes.locale, sets: fetchedSets, screenshots: fetchedScreenshots)
            await hydrateScreenshotImageCache(
                screenshots: fetchedScreenshots,
                previousScreenshotIDs: previousScreenshotIDs,
                force: force
            )
        } catch {
            print("Failed to load screenshots for locale \(loc.attributes.locale): \(error)")
        }
    }

    func screenshotSetsForLocale(_ locale: String) -> [ASCScreenshotSet] {
        screenshotSetsByLocale[screenshotCacheKey(locale: locale)] ?? []
    }

    func screenshotsForLocale(_ locale: String) -> [String: [ASCScreenshot]] {
        screenshotsByLocale[screenshotCacheKey(locale: locale)] ?? [:]
    }

    func cachedScreenshotImage(for slotId: String) -> NSImage? {
        screenshotImageCache[slotId]
    }

    func cacheScreenshotImage(_ image: NSImage, for slotId: String) {
        screenshotImageCache[slotId] = image
        syncCachedImage(image, for: slotId, in: &trackSlots)
        syncCachedImage(image, for: slotId, in: &savedTrackState)
    }

    func hydrateScreenshotImageCache(
        screenshots: [String: [ASCScreenshot]],
        previousScreenshotIDs: Set<String> = [],
        force: Bool,
        loader: ((URL) async -> NSImage?)? = nil
    ) async {
        let currentScreenshotIDs = screenshotIDs(in: screenshots)
        removeCachedScreenshotImages(for: previousScreenshotIDs.subtracting(currentScreenshotIDs))

        let resolvedLoader = loader ?? { url in
            await Self.loadScreenshotImage(from: url)
        }

        for shot in screenshots.values.flatMap({ $0 }) {
            guard let url = shot.imageURL else { continue }
            if !force, screenshotImageCache[shot.id] != nil { continue }
            guard let image = await resolvedLoader(url) else { continue }
            cacheScreenshotImage(image, for: shot.id)
        }

        purgeUnreferencedScreenshotImages(keeping: currentScreenshotIDs)
    }

    func updateScreenshotCache(
        locale: String,
        sets: [ASCScreenshotSet],
        screenshots: [String: [ASCScreenshot]]
    ) {
        let cacheKey = screenshotCacheKey(locale: locale)
        screenshotSetsByLocale[cacheKey] = sets
        screenshotsByLocale[cacheKey] = screenshots
        for displayType in trackDisplayTypes(for: locale) {
            loadTrackFromASC(displayType: displayType, locale: locale)
        }
    }

    private func trackDisplayTypes(for locale: String) -> Set<String> {
        let cacheKey = screenshotCacheKey(locale: locale)
        var displayTypes = Set(screenshotSetsForLocale(locale).map(\.attributes.screenshotDisplayType))
        for key in Set(trackSlots.keys).union(savedTrackState.keys) {
            if let displayType = displayType(fromTrackKey: key, cacheKey: cacheKey) {
                displayTypes.insert(displayType)
            }
        }
        return displayTypes
    }

    func orderedKnownScreenshotDisplayTypes(
        for locale: String,
        preferredOrder: [String] = ["APP_IPHONE_67", "APP_IPAD_PRO_3GEN_129", "APP_DESKTOP"]
    ) -> [String] {
        let known = trackDisplayTypes(for: locale)
        let preferred = preferredOrder.filter { known.contains($0) }
        let remaining = known.subtracting(preferred).sorted()
        return preferred + remaining
    }

    private func displayType(fromTrackKey key: String, cacheKey: String) -> String? {
        let prefix = "\(cacheKey)::"
        guard key.hasPrefix(prefix) else { return nil }
        return String(key.dropFirst(prefix.count))
    }

    func fetchScreenshotData(
        localizationId: String,
        service: AppStoreConnectService
    ) async throws -> ([ASCScreenshotSet], [String: [ASCScreenshot]]) {
        let fetchedSets = try await service.fetchScreenshotSets(localizationId: localizationId)
        let fetchedScreenshots = try await withThrowingTaskGroup(of: (String, [ASCScreenshot]).self) { group in
            for set in fetchedSets {
                group.addTask {
                    let screenshots = try await service.fetchScreenshots(setId: set.id)
                    return (set.id, screenshots)
                }
            }

            var pairs: [(String, [ASCScreenshot])] = []
            for try await pair in group {
                pairs.append(pair)
            }
            return pairs
        }

        return (fetchedSets, Dictionary(uniqueKeysWithValues: fetchedScreenshots))
    }

    func buildTrackSlotsFromASC(
        displayType: String,
        locale: String,
        previousSlots: [TrackSlot?] = []
    ) -> [TrackSlot?] {
        let set = screenshotSetsForLocale(locale).first { $0.attributes.screenshotDisplayType == displayType }
        var slots: [TrackSlot?] = Array(repeating: nil, count: 10)
        if let set, let shots = screenshotsForLocale(locale)[set.id] {
            for (i, shot) in shots.prefix(10).enumerated() {
                var localImage = cachedScreenshotImage(for: shot.id)
                let localPath = resolvedLocalSourcePath(for: shot, previousSlots: previousSlots)
                if localImage == nil {
                    if i < previousSlots.count, let prev = previousSlots[i], prev.id == shot.id {
                        localImage = prev.localImage
                    } else if let localPath,
                              let image = NSImage(contentsOfFile: localPath) {
                        localImage = image
                    } else if i < previousSlots.count, let prev = previousSlots[i] {
                        localImage = prev.localImage
                    }
                }
                slots[i] = TrackSlot(
                    id: shot.id,
                    localPath: localPath,
                    localImage: localImage,
                    ascScreenshot: shot,
                    isFromASC: true
                )
            }
        }
        return slots
    }

    private func resolvedLocalSourcePath(for screenshot: ASCScreenshot, previousSlots: [TrackSlot?]) -> String? {
        let targetFileName = screenshot.attributes.fileName?.lowercased()

        func matches(_ slot: TrackSlot) -> Bool {
            guard let localPath = slot.localPath,
                  FileManager.default.fileExists(atPath: localPath) else {
                return false
            }
            if slot.id == screenshot.id {
                return true
            }
            let localFileName = URL(fileURLWithPath: localPath).lastPathComponent.lowercased()
            if let targetFileName {
                if slot.ascScreenshot?.attributes.fileName?.lowercased() == targetFileName {
                    return true
                }
                if localFileName == targetFileName {
                    return true
                }
            }
            return false
        }

        if let matched = previousSlots.compactMap({ $0 }).first(where: matches) {
            return matched.localPath
        }

        guard let targetFileName,
              let projectId = appState?.activeProjectId else {
            return nil
        }

        let candidate = BlitzPaths.screenshots(projectId: projectId).appendingPathComponent(targetFileName)
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            return nil
        }
        return candidate.path
    }

    func invalidateStaleTrackSnapshots(displayType: String, locale: String) {
        let trackKey = screenshotTrackKey(displayType: displayType, locale: locale)
        let latestRemoteSlots = buildTrackSlotsFromASC(
            displayType: displayType,
            locale: locale,
            previousSlots: trackSlots[trackKey] ?? []
        )
        let validRemoteIDs = Set(latestRemoteSlots.compactMap { slot -> String? in
            guard let slot, slot.isFromASC else { return nil }
            return slot.id
        })

        let current = trackSlots[trackKey] ?? Array(repeating: nil, count: 10)
        let sanitizedCurrent = sanitizeTrackSlots(current, validRemoteScreenshotIDs: validRemoteIDs)

        trackSlots[trackKey] = sanitizedCurrent
        savedTrackState[trackKey] = latestRemoteSlots
        purgeUnreferencedScreenshotImages(keeping: validRemoteIDs)
    }

    private func sanitizeTrackSlots(
        _ slots: [TrackSlot?],
        validRemoteScreenshotIDs: Set<String>
    ) -> [TrackSlot?] {
        let sanitized = slots.compactMap { slot -> TrackSlot? in
            guard let slot else { return nil }
            if slot.isFromASC && !validRemoteScreenshotIDs.contains(slot.id) {
                return nil
            }
            return slot
        }

        var padded = sanitized.map(Optional.some)
        if padded.count > 10 {
            padded = Array(padded.prefix(10))
        }
        while padded.count < 10 {
            padded.append(nil)
        }
        return padded
    }

    private func ensureScreenshotLocalizationsLoaded(service: AppStoreConnectService) async {
        if localizations.isEmpty, let versionId = selectedVersion?.id ?? syncSelectedVersion() {
            localizations = (try? await service.fetchLocalizations(versionId: versionId)) ?? []
        }
        if localizations.isEmpty, let appId = app?.id {
            let versions = (try? await service.fetchAppStoreVersions(appId: appId)) ?? []
            appStoreVersions = versions
            if let versionId = syncSelectedVersion() {
                localizations = (try? await service.fetchLocalizations(versionId: versionId)) ?? []
            }
        }
    }

    // MARK: - Track Synchronization

    func requiresFullTrackRebuild(current: [TrackSlot?], saved: [TrackSlot?]) -> Bool {
        let currentFilled = current.compactMap { $0 }
        let currentRemoteIds = currentFilled.compactMap { slot -> String? in
            guard slot.isFromASC else { return nil }
            return slot.id
        }
        let currentRemoteIdSet = Set(currentRemoteIds)
        let savedRemainingRemoteIds = saved.compactMap { slot -> String? in
            guard let slot, slot.isFromASC, currentRemoteIdSet.contains(slot.id) else { return nil }
            return slot.id
        }

        if currentRemoteIds != savedRemainingRemoteIds {
            return true
        }

        var sawLocalSlot = false
        for slot in currentFilled {
            if slot.isFromASC {
                if sawLocalSlot {
                    return true
                }
            } else {
                sawLocalSlot = true
            }
        }

        return false
    }

    private func prepareTrackUploads(
        current: [TrackSlot?],
        fullRebuild: Bool
    ) async throws -> [PreparedTrackUpload] {
        var uploads: [PreparedTrackUpload] = []
        uploads.reserveCapacity(current.compactMap { $0 }.count)

        for slot in current {
            guard let slot else { continue }
            if let localPath = slot.localPath {
                guard FileManager.default.fileExists(atPath: localPath) else {
                    throw NSError(
                        domain: "ASCManager",
                        code: 5,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Local screenshot file is missing at \(localPath). Re-add it and save again."
                        ]
                    )
                }
                uploads.append(PreparedTrackUpload(path: localPath, isTemporary: false))
                continue
            }
            guard fullRebuild else {
                continue
            }
            guard slot.isFromASC, let screenshot = slot.ascScreenshot else {
                throw NSError(
                    domain: "ASCManager",
                    code: 6,
                    userInfo: [
                        NSLocalizedDescriptionKey: "A staged screenshot could not be resolved for re-upload. Refresh the screenshots tab and try again."
                    ]
                )
            }
            uploads.append(try await stageRemoteScreenshotForReupload(screenshot))
        }

        return uploads
    }

    private func stageRemoteScreenshotForReupload(_ screenshot: ASCScreenshot) async throws -> PreparedTrackUpload {
        guard let downloadURL = screenshot.originalImageURL else {
            throw NSError(
                domain: "ASCManager",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Could not download the original screenshot for '\(screenshot.attributes.fileName ?? screenshot.id)'. Re-add it locally and save again."
                ]
            )
        }

        let (data, response) = try await URLSession.shared.data(from: downloadURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NSError(
                domain: "ASCManager",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Downloading '\(screenshot.attributes.fileName ?? screenshot.id)' failed with status \(http.statusCode)."
                ]
            )
        }

        guard let image = Self.decodeScreenshotImage(from: data) else {
            throw NSError(
                domain: "ASCManager",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey: "Downloaded screenshot '\(screenshot.attributes.fileName ?? screenshot.id)' was unreadable."
                ]
            )
        }

        if let expectedWidth = screenshot.attributes.imageAsset?.width,
           let expectedHeight = screenshot.attributes.imageAsset?.height {
            let actualSize = Self.pixelDimensions(for: image)
            guard actualSize.width == expectedWidth, actualSize.height == expectedHeight else {
                throw NSError(
                    domain: "ASCManager",
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Downloaded screenshot '\(screenshot.attributes.fileName ?? screenshot.id)' had unexpected dimensions \(actualSize.width)x\(actualSize.height); expected \(expectedWidth)x\(expectedHeight)."
                    ]
                )
            }
        }

        let baseName = screenshot.attributes.fileName?.isEmpty == false
            ? screenshot.attributes.fileName!
            : "\(screenshot.id).png"
        let stagedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("blitz-screenshot-\(UUID().uuidString)-\(baseName)")
        try data.write(to: stagedURL, options: .atomic)
        return PreparedTrackUpload(path: stagedURL.path, isTemporary: true)
    }

    func syncTrackToASC(displayType: String, locale: String) async {
        guard let service else {
            writeError = "ASC service not configured"
            return
        }

        isSyncing = true
        defer { isSyncing = false }
        writeError = nil

        await ensureScreenshotLocalizationsLoaded(service: service)
        guard let loc = localizations.first(where: { $0.attributes.locale == locale })
                ?? localizations.first else {
            writeError = "No localizations found for locale '\(locale)'."
            return
        }

        let trackKey = screenshotTrackKey(displayType: displayType, locale: loc.attributes.locale)
        let startedAt = Date()

        do {
            // Refresh the remote baseline before diffing so stale cached ASC IDs
            // don't survive server-side edits made outside Blitz.
            await loadScreenshots(locale: loc.attributes.locale, force: true)
            invalidateStaleTrackSnapshots(displayType: displayType, locale: loc.attributes.locale)

            let current = trackSlots[trackKey] ?? Array(repeating: nil, count: 10)
            let saved = savedTrackState[trackKey] ?? Array(repeating: nil, count: 10)
            let savedRemoteIds = Set(saved.compactMap { slot -> String? in
                guard let slot, slot.isFromASC else { return nil }
                return slot.id
            })
            let currentRemoteIds = Set(current.compactMap { slot -> String? in
                guard let slot, slot.isFromASC else { return nil }
                return slot.id
            })
            let fullRebuild = requiresFullTrackRebuild(current: current, saved: saved)
            let uploads = try await prepareTrackUploads(current: current, fullRebuild: fullRebuild)
            defer {
                for upload in uploads where upload.isTemporary {
                    try? FileManager.default.removeItem(atPath: upload.path)
                }
            }

            let idsToDelete = fullRebuild
                ? savedRemoteIds
                : savedRemoteIds.subtracting(currentRemoteIds)
            for id in idsToDelete {
                try await service.deleteScreenshot(screenshotId: id)
            }
            removeCachedScreenshotImages(for: idsToDelete)

            for upload in uploads {
                try await service.uploadScreenshot(localizationId: loc.id, path: upload.path, displayType: displayType)
            }

            await loadScreenshots(locale: loc.attributes.locale, force: true)
            loadTrackFromASC(displayType: displayType, locale: loc.attributes.locale, overwriteUnsaved: true)
            purgeUnreferencedScreenshotImages()
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "screenshots.save",
                success: true,
                startedAt: startedAt
            )
        } catch {
            writeError = error.localizedDescription
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "screenshots.save",
                success: false,
                startedAt: startedAt
            )
        }
    }

    // MARK: - Screenshot Deletion

    func deleteScreenshot(screenshotId: String) async throws {
        guard let service else { throw ASCError.notFound("ASC service not configured") }
        try await service.deleteScreenshot(screenshotId: screenshotId)
    }

    // MARK: - Track Management

    @discardableResult
    func addAssetToTrack(
        displayType: String,
        slotIndex: Int,
        localPath: String,
        locale: String = "en-US"
    ) -> String? {
        guard slotIndex >= 0 && slotIndex < 10 else { return "Invalid slot index" }
        guard let image = NSImage(contentsOfFile: localPath) else {
            return "Could not load image"
        }

        var pixelWidth = 0
        var pixelHeight = 0
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            pixelWidth = rep.pixelsWide
            pixelHeight = rep.pixelsHigh
        } else if let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff) {
            pixelWidth = bitmap.pixelsWide
            pixelHeight = bitmap.pixelsHigh
        }

        if let error = Self.validateDimensions(width: pixelWidth, height: pixelHeight, displayType: displayType) {
            return error
        }

        let trackKey = screenshotTrackKey(displayType: displayType, locale: locale)
        var slots = trackSlots[trackKey] ?? Array(repeating: nil, count: 10)
        let slot = TrackSlot(
            id: UUID().uuidString,
            localPath: localPath,
            localImage: image,
            ascScreenshot: nil,
            isFromASC: false
        )

        if slots[slotIndex] != nil {
            slots.insert(slot, at: slotIndex)
            let removedSlot = slots.count > 10 ? slots[10] : nil
            slots = Array(slots.prefix(10))
            if let removedSlot {
                removeCachedScreenshotImages(for: [removedSlot.id])
            }
        } else {
            slots[slotIndex] = slot
        }

        while slots.count < 10 { slots.append(nil) }
        trackSlots[trackKey] = slots
        cacheScreenshotImage(image, for: slot.id)
        return nil
    }

    func removeFromTrack(displayType: String, slotIndex: Int, locale: String = "en-US") {
        guard slotIndex >= 0 && slotIndex < 10 else { return }
        let trackKey = screenshotTrackKey(displayType: displayType, locale: locale)
        var slots = trackSlots[trackKey] ?? Array(repeating: nil, count: 10)
        let removed = slots.remove(at: slotIndex)
        slots.append(nil)
        trackSlots[trackKey] = slots
        if let removed {
            removeCachedScreenshotImages(for: [removed.id])
        }
        purgeUnreferencedScreenshotImages()
    }

    func reorderTrack(
        displayType: String,
        fromIndex: Int,
        toIndex: Int,
        locale: String = "en-US"
    ) {
        guard fromIndex >= 0 && fromIndex < 10 && toIndex >= 0 && toIndex < 10 else { return }
        guard fromIndex != toIndex else { return }
        let trackKey = screenshotTrackKey(displayType: displayType, locale: locale)
        var slots = trackSlots[trackKey] ?? Array(repeating: nil, count: 10)
        let item = slots.remove(at: fromIndex)
        slots.insert(item, at: toIndex)
        trackSlots[trackKey] = slots
    }

    @discardableResult
    func reorderTrack(
        displayType: String,
        order: [Int],
        locale: String = "en-US"
    ) -> String? {
        guard order.count == 10 else {
            return "Order must contain exactly 10 indexes."
        }
        let expected = Set(0..<10)
        let provided = Set(order)
        guard provided == expected else {
            return "Order must be a permutation of indexes 0 through 9."
        }

        let trackKey = screenshotTrackKey(displayType: displayType, locale: locale)
        let slots = trackSlots[trackKey] ?? Array(repeating: nil, count: 10)
        trackSlots[trackKey] = order.map { slots[$0] }
        return nil
    }

    // MARK: - Track Loading

    func loadTrackFromASC(
        displayType: String,
        locale: String = "en-US",
        overwriteUnsaved: Bool = false
    ) {
        if !overwriteUnsaved, hasUnsavedChanges(displayType: displayType, locale: locale) {
            return
        }
        let trackKey = screenshotTrackKey(displayType: displayType, locale: locale)
        let previousSlots = trackSlots[trackKey] ?? []
        let slots = buildTrackSlotsFromASC(displayType: displayType, locale: locale, previousSlots: previousSlots)
        trackSlots[trackKey] = slots
        savedTrackState[trackKey] = slots
        purgeUnreferencedScreenshotImages(keeping: screenshotIDs(in: screenshotsForLocale(locale)))
    }

    // MARK: - Validation

    func hasUnsavedChanges(displayType: String, locale: String = "en-US") -> Bool {
        let trackKey = screenshotTrackKey(displayType: displayType, locale: locale)
        let current = trackSlots[trackKey] ?? Array(repeating: nil, count: 10)
        let saved = savedTrackState[trackKey] ?? Array(repeating: nil, count: 10)
        return zip(current, saved).contains { c, s in c?.id != s?.id }
    }

    /// Validate pixel dimensions for a display type. Returns nil if valid, or an error string.
    nonisolated static func validateDimensions(width: Int, height: Int, displayType: String) -> String? {
        let normalizedDisplayType = displayType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let validDimensions = screenshotDimensionsByDisplayType[normalizedDisplayType] else {
            return nil
        }

        if validDimensions.contains(where: { $0.width == width && $0.height == height }) {
            return nil
        }

        let allowed = screenshotDimensionSummary(displayType: normalizedDisplayType) ?? "a supported screenshot size"
        return "\(width)×\(height) — need \(allowed) for \(screenshotDisplayName(displayType: normalizedDisplayType))"
    }

    nonisolated static func screenshotDimensionSummary(displayType: String) -> String? {
        switch displayType.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "APP_IPHONE_67":
            return "1260×2736, 1290×2796, or 1320×2868 (portrait or landscape)"
        case "APP_IPAD_PRO_3GEN_129":
            return "2048×2732 or 2064×2752 (portrait or landscape)"
        case "APP_DESKTOP":
            return "1280×800, 1440×900, 2560×1600, or 2880×1800"
        default:
            return nil
        }
    }

    nonisolated private static func screenshotDisplayName(displayType: String) -> String {
        switch displayType {
        case "APP_IPHONE_67":
            return "iPhone"
        case "APP_IPAD_PRO_3GEN_129":
            return "iPad"
        case "APP_DESKTOP":
            return "Mac"
        default:
            return "this display type"
        }
    }

    private func screenshotIDs(in screenshots: [String: [ASCScreenshot]]) -> Set<String> {
        Set(screenshots.values.flatMap { $0.map(\.id) })
    }

    private func removeCachedScreenshotImages<S: Sequence>(for slotIds: S) where S.Element == String {
        for slotId in slotIds {
            screenshotImageCache.removeValue(forKey: slotId)
            syncCachedImage(nil, for: slotId, in: &trackSlots)
            syncCachedImage(nil, for: slotId, in: &savedTrackState)
        }
    }

    private func purgeUnreferencedScreenshotImages(keeping protectedIDs: Set<String> = []) {
        let referencedTrackIDs = Set(trackSlots.values.flatMap { slots in
            slots.compactMap { $0?.id }
        })
        let referencedSavedIDs = Set(savedTrackState.values.flatMap { slots in
            slots.compactMap { $0?.id }
        })
        let retainedIDs = referencedTrackIDs.union(referencedSavedIDs).union(protectedIDs)
        screenshotImageCache = screenshotImageCache.filter { retainedIDs.contains($0.key) }
    }

    private func syncCachedImage(
        _ image: NSImage?,
        for slotId: String,
        in storage: inout [String: [TrackSlot?]]
    ) {
        for key in Array(storage.keys) {
            guard var slots = storage[key] else { continue }
            var didChange = false
            for index in slots.indices {
                guard var slot = slots[index], slot.id == slotId else { continue }
                slot.localImage = image
                slots[index] = slot
                didChange = true
            }
            if didChange {
                storage[key] = slots
            }
        }
    }

    nonisolated private static func loadScreenshotImage(from url: URL) async -> NSImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else {
            return nil
        }
        return decodeScreenshotImage(from: data)
    }

    nonisolated private static func decodeScreenshotImage(from data: Data) -> NSImage? {
        if let image = NSImage(data: data), !image.representations.isEmpty {
            return image
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    nonisolated private static func pixelDimensions(for image: NSImage) -> (width: Int, height: Int) {
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return (rep.pixelsWide, rep.pixelsHigh)
        }
        if let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff) {
            return (bitmap.pixelsWide, bitmap.pixelsHigh)
        }
        return (Int(image.size.width), Int(image.size.height))
    }
}

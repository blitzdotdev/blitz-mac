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
           screenshotsByLocale[cacheKey] != nil {
            return
        }

        await ensureScreenshotLocalizationsLoaded(service: service)
        guard let loc = localizations.first(where: { $0.attributes.locale == locale })
                ?? localizations.first else {
            return
        }

        do {
            let (fetchedSets, fetchedScreenshots) = try await fetchScreenshotData(
                localizationId: loc.id,
                service: service
            )
            updateScreenshotCache(locale: loc.attributes.locale, sets: fetchedSets, screenshots: fetchedScreenshots)
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
                var localImage: NSImage? = nil
                if shot.imageURL == nil, i < previousSlots.count, let prev = previousSlots[i] {
                    localImage = prev.localImage
                }
                slots[i] = TrackSlot(
                    id: shot.id,
                    localPath: nil,
                    localImage: localImage,
                    ascScreenshot: shot,
                    isFromASC: true
                )
            }
        }
        return slots
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
            let savedIds = Set(saved.compactMap { $0?.id })
            let currentIds = Set(current.compactMap { $0?.id })
            let toDelete = savedIds.subtracting(currentIds)
            for id in toDelete {
                try await service.deleteScreenshot(screenshotId: id)
            }

            let currentASCIds = current.compactMap { slot -> String? in
                guard let slot, slot.isFromASC else { return nil }
                return slot.id
            }
            let savedASCIds = saved.compactMap { slot -> String? in
                guard let slot, slot.isFromASC else { return nil }
                return slot.id
            }
            let remainingASCIds = Set(currentASCIds)
            let reorderNeeded = currentASCIds != savedASCIds.filter { remainingASCIds.contains($0) }

            if reorderNeeded {
                for id in currentASCIds where !toDelete.contains(id) {
                    try await service.deleteScreenshot(screenshotId: id)
                }
            }

            for slot in current {
                guard let slot else { continue }
                if let path = slot.localPath {
                    try await service.uploadScreenshot(localizationId: loc.id, path: path, displayType: displayType)
                } else if reorderNeeded, slot.isFromASC, let ascShot = slot.ascScreenshot {
                    if let url = ascShot.imageURL,
                       let (data, _) = try? await URLSession.shared.data(from: url),
                       let fileName = ascShot.attributes.fileName {
                        let tmpPath = FileManager.default.temporaryDirectory.appendingPathComponent(fileName).path
                        try data.write(to: URL(fileURLWithPath: tmpPath))
                        try await service.uploadScreenshot(localizationId: loc.id, path: tmpPath, displayType: displayType)
                        try? FileManager.default.removeItem(atPath: tmpPath)
                    }
                }
            }

            await loadScreenshots(locale: loc.attributes.locale, force: true)
            loadTrackFromASC(displayType: displayType, locale: loc.attributes.locale, overwriteUnsaved: true)
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

    // MARK: - Local Assets

    func scanLocalAssets(projectId: String) {
        let dir = BlitzPaths.screenshots(projectId: projectId)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            localScreenshotAssets = []
            return
        }
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]
        localScreenshotAssets = files
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                var image = NSImage(contentsOf: url)
                if image == nil || image!.representations.isEmpty {
                    if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                       let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                        image = NSImage(
                            cgImage: cgImage,
                            size: NSSize(width: cgImage.width, height: cgImage.height)
                        )
                    }
                }
                guard let image else { return nil }
                return LocalScreenshotAsset(id: UUID(), url: url, image: image, fileName: url.lastPathComponent)
            }
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
            slots = Array(slots.prefix(10))
        } else {
            slots[slotIndex] = slot
        }

        while slots.count < 10 { slots.append(nil) }
        trackSlots[trackKey] = slots
        return nil
    }

    func removeFromTrack(displayType: String, slotIndex: Int, locale: String = "en-US") {
        guard slotIndex >= 0 && slotIndex < 10 else { return }
        let trackKey = screenshotTrackKey(displayType: displayType, locale: locale)
        var slots = trackSlots[trackKey] ?? Array(repeating: nil, count: 10)
        slots.remove(at: slotIndex)
        slots.append(nil)
        trackSlots[trackKey] = slots
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
}

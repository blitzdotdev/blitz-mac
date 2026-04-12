import Foundation
import Testing
import AppKit
@testable import Blitz

@MainActor
@Test func loadTrackFromASCPreservesUnsavedLocaleTrack() {
    let manager = ASCManager()
    let locale = "en-US"
    let displayType = "APP_IPHONE_67"
    let set = makeScreenshotSet(id: "set-us", displayType: displayType, count: 1)

    manager.updateScreenshotCache(
        locale: locale,
        sets: [set],
        screenshots: [set.id: [makeScreenshot(id: "remote-1", fileName: "remote-1.png")]]
    )
    manager.loadTrackFromASC(displayType: displayType, locale: locale)

    let trackKey = manager.screenshotTrackKey(displayType: displayType, locale: locale)
    manager.trackSlots[trackKey] = [
        TrackSlot(
            id: "local-1",
            localPath: "/tmp/local-1.png",
            localImage: nil,
            ascScreenshot: nil,
            isFromASC: false
        )
    ] + Array(repeating: nil, count: 9)

    #expect(manager.hasUnsavedChanges(displayType: displayType, locale: locale))

    manager.updateScreenshotCache(
        locale: locale,
        sets: [set],
        screenshots: [set.id: [makeScreenshot(id: "remote-2", fileName: "remote-2.png")]]
    )
    manager.loadTrackFromASC(displayType: displayType, locale: locale)

    let slots = manager.trackSlotsForDisplayType(displayType, locale: locale)
    #expect(slots[0]?.id == "local-1")
    #expect(manager.hasUnsavedChanges(displayType: displayType, locale: locale))
}

@MainActor
@Test func hydrateScreenshotImageCacheOverwritesOnForceRefresh() async {
    let manager = ASCManager()
    let shot = makeScreenshot(
        id: "remote-1",
        fileName: "remote-1.png",
        templateURL: "https://example.com/remote-1.png"
    )
    let initialImage = makeTestImage()
    let refreshedImage = makeTestImage()

    await manager.hydrateScreenshotImageCache(
        screenshots: ["set-1": [shot]],
        force: false,
        loader: { _ in initialImage }
    )
    #expect(manager.cachedScreenshotImage(for: shot.id) === initialImage)

    await manager.hydrateScreenshotImageCache(
        screenshots: ["set-1": [shot]],
        force: false,
        loader: { _ in refreshedImage }
    )
    #expect(manager.cachedScreenshotImage(for: shot.id) === initialImage)

    await manager.hydrateScreenshotImageCache(
        screenshots: ["set-1": [shot]],
        force: true,
        loader: { _ in refreshedImage }
    )
    #expect(manager.cachedScreenshotImage(for: shot.id) === refreshedImage)
}

@MainActor
@Test func loadTrackFromASCUsesCachedRemoteImage() {
    let manager = ASCManager()
    let locale = "en-US"
    let displayType = "APP_IPHONE_67"
    let cachedImage = makeTestImage()
    let set = makeScreenshotSet(id: "set-us", displayType: displayType, count: 1)

    manager.cacheScreenshotImage(cachedImage, for: "remote-1")
    manager.updateScreenshotCache(
        locale: locale,
        sets: [set],
        screenshots: [set.id: [
            makeScreenshot(
                id: "remote-1",
                fileName: "remote-1.png",
                templateURL: "https://example.com/remote-1.png"
            )
        ]]
    )
    manager.loadTrackFromASC(displayType: displayType, locale: locale)

    let slot = manager.trackSlotsForDisplayType(displayType, locale: locale)[0]
    #expect(slot?.localImage === cachedImage)
}

@MainActor
@Test func removeFromTrackClearsCachedImage() {
    let manager = ASCManager()
    let locale = "en-US"
    let displayType = "APP_IPHONE_67"
    let trackKey = manager.screenshotTrackKey(displayType: displayType, locale: locale)
    let image = makeTestImage()

    manager.trackSlots[trackKey] = [
        TrackSlot(
            id: "local-1",
            localPath: "/tmp/local-1.png",
            localImage: nil,
            ascScreenshot: nil,
            isFromASC: false
        )
    ] + Array(repeating: nil, count: 9)
    manager.cacheScreenshotImage(image, for: "local-1")

    manager.removeFromTrack(displayType: displayType, slotIndex: 0, locale: locale)

    #expect(manager.cachedScreenshotImage(for: "local-1") == nil)
    #expect(manager.trackSlotsForDisplayType(displayType, locale: locale).allSatisfy { $0 == nil })
}

@MainActor
@Test func addAssetToTrackCachesLocalImage() throws {
    let manager = ASCManager()
    let locale = "en-US"
    let displayType = "APP_IPHONE_67"
    let imagePath = try writeValidScreenshotPNG(
        width: 1260,
        height: 2736,
        fileName: UUID().uuidString + ".png"
    )

    let error = manager.addAssetToTrack(
        displayType: displayType,
        slotIndex: 0,
        localPath: imagePath,
        locale: locale
    )

    #expect(error == nil)
    let slot = manager.trackSlotsForDisplayType(displayType, locale: locale)[0]
    #expect(slot?.localImage != nil)
    #expect(slot.map { manager.cachedScreenshotImage(for: $0.id) != nil } == true)
}

@MainActor
@Test func submissionReadinessUsesPrimaryLocaleScreenshotCache() {
    let manager = ASCManager()
    manager.app = makeApp(primaryLocale: "en-US")
    manager.localizations = [
        makeLocalization(id: "loc-gb", locale: "en-GB"),
        makeLocalization(id: "loc-us", locale: "en-US"),
    ]

    let usSet = makeScreenshotSet(id: "set-us", displayType: "APP_IPHONE_67", count: 1)
    manager.updateScreenshotCache(
        locale: "en-US",
        sets: [usSet],
        screenshots: [usSet.id: [makeScreenshot(id: "shot-us", fileName: "us.png")]]
    )

    manager.selectedScreenshotsLocale = "en-GB"

    let readiness = manager.submissionReadiness
    let iphoneField = readiness.fields.first { $0.label == "iPhone Screenshots" }

    #expect(iphoneField?.value == "1 screenshot(s)")
}

@MainActor
@Test func submissionReadinessUsesPrimaryLocaleMetadataWhenAPIOrderDiffers() {
    let manager = ASCManager()
    manager.app = makeApp(primaryLocale: "en-US")
    manager.localizations = [
        makeLocalization(
            id: "loc-ja",
            locale: "ja",
            title: "Japanese Title",
            description: "Japanese Description",
            keywords: "japanese,keywords",
            supportUrl: "https://example.com/ja/support"
        ),
        makeLocalization(
            id: "loc-us",
            locale: "en-US",
            title: "English Title",
            description: "English Description",
            keywords: "english,keywords",
            supportUrl: "https://example.com/en/support"
        ),
    ]
    manager.appInfoLocalizationsByLocale = [
        "ja": makeAppInfoLocalization(
            id: "info-ja",
            locale: "ja",
            name: "Japanese Name",
            privacyPolicyUrl: "https://example.com/ja/privacy"
        ),
        "en-US": makeAppInfoLocalization(
            id: "info-us",
            locale: "en-US",
            name: "English Name",
            privacyPolicyUrl: "https://example.com/en/privacy"
        ),
    ]
    manager.appInfoLocalization = manager.appInfoLocalizationsByLocale["ja"]

    func value(for label: String) -> String? {
        manager.submissionReadiness.fields.first(where: { $0.label == label })?.value
    }

    #expect(value(for: "App Name") == "English Name")
    #expect(value(for: "Description") == "English Description")
    #expect(value(for: "Keywords") == "english,keywords")
    #expect(value(for: "Support URL") == "https://example.com/en/support")
    #expect(value(for: "Privacy Policy URL") == "https://example.com/en/privacy")
}

@Test func screenshotValidationAcceptsHelperCatalogIpadVariants() {
    #expect(
        ASCManager.validateDimensions(
            width: 2064,
            height: 2752,
            displayType: "APP_IPAD_PRO_3GEN_129"
        ) == nil
    )
    #expect(
        ASCManager.validateDimensions(
            width: 2752,
            height: 2064,
            displayType: "APP_IPAD_PRO_3GEN_129"
        ) == nil
    )
}

@Test func screenshotValidationAcceptsExpandedIPhone67Catalog() {
    #expect(
        ASCManager.validateDimensions(
            width: 1320,
            height: 2868,
            displayType: "APP_IPHONE_67"
        ) == nil
    )
    #expect(
        ASCManager.validateDimensions(
            width: 2868,
            height: 1320,
            displayType: "APP_IPHONE_67"
        ) == nil
    )
}

@Test func screenshotDimensionSummaryMatchesHelperCatalog() {
    #expect(
        ASCManager.screenshotDimensionSummary(displayType: "APP_IPAD_PRO_3GEN_129")
            == "2048×2732 or 2064×2752 (portrait or landscape)"
    )
    #expect(
        ASCManager.screenshotDimensionSummary(displayType: "APP_IPHONE_67")
            == "1260×2736, 1290×2796, or 1320×2868 (portrait or landscape)"
    )
}

private func makeApp(primaryLocale: String?) -> ASCApp {
    ASCApp(
        id: "app-id",
        attributes: ASCApp.Attributes(
            bundleId: "com.example.blitz",
            name: "Blitz",
            primaryLocale: primaryLocale,
            vendorNumber: nil,
            contentRightsDeclaration: nil
        )
    )
}

private func makeLocalization(
    id: String,
    locale: String,
    title: String? = nil,
    description: String? = nil,
    keywords: String? = nil,
    supportUrl: String? = nil
) -> ASCVersionLocalization {
    ASCVersionLocalization(
        id: id,
        attributes: ASCVersionLocalization.Attributes(
            locale: locale,
            title: title,
            subtitle: nil,
            description: description,
            keywords: keywords,
            promotionalText: nil,
            marketingUrl: nil,
            supportUrl: supportUrl,
            whatsNew: nil
        )
    )
}

private func makeAppInfoLocalization(
    id: String,
    locale: String,
    name: String? = nil,
    privacyPolicyUrl: String? = nil
) -> ASCAppInfoLocalization {
    ASCAppInfoLocalization(
        id: id,
        attributes: ASCAppInfoLocalization.Attributes(
            locale: locale,
            name: name,
            subtitle: nil,
            privacyPolicyUrl: privacyPolicyUrl,
            privacyChoicesUrl: nil,
            privacyPolicyText: nil
        )
    )
}

private func makeScreenshotSet(id: String, displayType: String, count: Int?) -> ASCScreenshotSet {
    ASCScreenshotSet(
        id: id,
        attributes: ASCScreenshotSet.Attributes(
            screenshotDisplayType: displayType,
            screenshotCount: count
        )
    )
}

private func makeScreenshot(id: String, fileName: String, templateURL: String? = nil) -> ASCScreenshot {
    ASCScreenshot(
        id: id,
        attributes: ASCScreenshot.Attributes(
            fileName: fileName,
            fileSize: nil,
            imageAsset: templateURL.map {
                ASCScreenshot.Attributes.ImageAsset(
                    templateUrl: $0,
                    width: 400,
                    height: 800
                )
            },
            assetDeliveryState: nil
        )
    )
}

private func makeTestImage() -> NSImage {
    let image = NSImage(size: NSSize(width: 12, height: 12))
    image.lockFocus()
    NSColor.white.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 12, height: 12)).fill()
    image.unlockFocus()
    return image
}

private func writeValidScreenshotPNG(width: Int, height: Int, fileName: String) throws -> String {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )
    guard let rep else {
        throw NSError(domain: "Tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create bitmap rep"])
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "Tests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }

    let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
    try data.write(to: url, options: .atomic)
    return url.path
}

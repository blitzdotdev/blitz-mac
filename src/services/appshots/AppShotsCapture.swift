import Foundation
import AppKit

// Thin capture helpers. No state; callers own cancellation.

enum AppShotsCapture {
    /// Snap the currently booted simulator to a temp PNG and load it.
    /// Auto-detects near-blank captures and marks them excluded.
    static func snapCurrentSimulator(udid: String) async throws -> CapturedShot {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("blitz-shot-\(Int(Date().timeIntervalSince1970 * 1000)).png").path
        try await SimctlClient().screenshot(udid: udid, path: path)
        guard let image = NSImage(contentsOfFile: path) else {
            throw NSError(domain: "AppShotsCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Screenshot saved but could not be loaded."])
        }
        let blank = isLikelyBlank(image)
        return CapturedShot(
            path: path,
            image: image,
            included: !blank,
            warning: blank ? "Looks nearly blank — auto-excluded." : nil
        )
    }

    /// Downsample to 16×16 and average luminance. Flags solid-black / solid-white / loading screens.
    static func isLikelyBlank(_ image: NSImage) -> Bool {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let size = 16
        let bytesPerRow = size * 4
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))

        var lumSum = 0
        var minLum = 255
        var maxLum = 0
        let count = size * size
        for i in 0..<count {
            let lum = (Int(pixels[i * 4]) + Int(pixels[i * 4 + 1]) + Int(pixels[i * 4 + 2])) / 3
            lumSum += lum
            if lum < minLum { minLum = lum }
            if lum > maxLum { maxLum = lum }
        }
        let avg = lumSum / count
        let range = maxLum - minLum
        // Nearly uniform AND extreme (dark or very light) → likely blank.
        return range < 12 && (avg < 20 || avg > 245)
    }

    /// Cheap rolling hash over the first 4KB of a file — enough to detect "same screen" duplicates.
    static func quickHash(of path: String) -> Int? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return data.withUnsafeBytes { ptr in
            var h = 5381
            for byte in ptr.bindMemory(to: UInt8.self).prefix(4096) {
                h = ((h << 5) &+ h) &+ Int(byte)
            }
            return h
        }
    }
}

/// Polling recorder — while running, captures one frame every `interval` seconds,
/// skipping duplicates by content hash. Append-on-new via `onNewShot`.
@MainActor
final class FlowRecorder {
    private var task: Task<Void, Never>?
    private(set) var isRunning = false

    func start(
        udid: String,
        interval: TimeInterval = 2.0,
        onNewShot: @MainActor @escaping (CapturedShot) -> Void
    ) {
        guard !isRunning else { return }
        isRunning = true
        task = Task { [weak self] in
            var lastHash: Int?
            while let self, await self.isRunning, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                if !(await self.isRunning) { break }
                do {
                    let shot = try await AppShotsCapture.snapCurrentSimulator(udid: udid)
                    let hash = AppShotsCapture.quickHash(of: shot.path)
                    if hash != nil, hash == lastHash { continue }
                    lastHash = hash
                    await MainActor.run { onNewShot(shot) }
                } catch {
                    // Ignore transient failures — just wait for the next tick.
                }
            }
        }
    }

    func stop() {
        isRunning = false
        task?.cancel()
        task = nil
    }
}

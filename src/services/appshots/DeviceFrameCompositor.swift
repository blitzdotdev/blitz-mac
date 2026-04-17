import Foundation
import AppKit
import CoreGraphics

// Loads iPhone bezel PNGs + insets.json from the app bundle, and composites
// raw screenshots into the device's screen area, producing a PNG suitable
// for feeding into `asc app-shots templates apply`.

struct DeviceFrameCompositor {
    let frames: [DeviceFrame]

    init() {
        self.frames = Self.loadFrames()
    }

    /// Composite a screenshot onto the named device frame. Returns a path to the temp PNG,
    /// or nil if resources are missing or drawing failed.
    func composite(screenshotPath: String, device: DeviceFrame) -> String? {
        guard let frameURL = Bundle.appResources.url(forResource: device.name, withExtension: "png"),
              let frameImage = NSImage(contentsOf: frameURL),
              let frameCG = frameImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let screenshotImage = NSImage(contentsOfFile: screenshotPath),
              let screenshotCG = screenshotImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let fw = device.outputWidth
        let fh = device.outputHeight
        let ix = device.screenInsetX
        let iy = device.screenInsetY
        let sw = fw - ix * 2
        let sh = fh - iy * 2

        guard let ctx = CGContext(
            data: nil, width: fw, height: fh,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let screenRect = CGRect(x: ix, y: fh - iy - sh, width: sw, height: sh)
        let cornerRadius = CGFloat(fw) * 0.055

        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: screenRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
        ctx.clip()
        ctx.draw(screenshotCG, in: screenRect)
        ctx.restoreGState()

        ctx.draw(frameCG, in: CGRect(x: 0, y: 0, width: fw, height: fh))

        guard let composited = ctx.makeImage() else { return nil }

        let tmpPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("blitz-framed-\(UUID().uuidString).png").path
        let bitmap = NSBitmapImageRep(cgImage: composited)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else { return nil }
        try? pngData.write(to: URL(fileURLWithPath: tmpPath))
        return tmpPath
    }

    static func loadFrames() -> [DeviceFrame] {
        let bundle = Bundle.appResources
        guard let url = bundle.url(forResource: "insets", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Int]] else {
            return []
        }
        return json.compactMap { (name, values) in
            guard bundle.url(forResource: name, withExtension: "png") != nil else { return nil }
            return DeviceFrame(
                name: name,
                outputWidth: values["outputWidth"] ?? 0,
                outputHeight: values["outputHeight"] ?? 0,
                screenInsetX: values["screenInsetX"] ?? 0,
                screenInsetY: values["screenInsetY"] ?? 0
            )
        }.sorted { $0.name < $1.name }
    }
}

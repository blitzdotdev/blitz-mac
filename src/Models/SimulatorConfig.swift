import Foundation

/// Per-device simulator display configuration
/// Ported from src/data/simulator-config.json
struct SimulatorDeviceConfig {
    let toolbarHeight: Double  // Simulator.app toolbar height in points
    let toolbarOffset: Double  // Extra offset within toolbar
    let widthPoints: Double    // Actual iPhone screen width in points
    let heightPoints: Double   // Actual iPhone screen height in points
    let borderX: Double        // Left/right bezel width (capture pixels / 2)
    let borderY: Double        // Top/bottom bezel height (capture pixels / 2)
}

/// Lookup simulator config by device name
struct SimulatorConfigDatabase {
    static let defaultConfig = SimulatorDeviceConfig(
        toolbarHeight: 40, toolbarOffset: 7.0,
        widthPoints: 393, heightPoints: 852,
        borderX: 21.0, borderY: 21.0
    )

    private static let devices: [String: SimulatorDeviceConfig] = [
        "iPhone SE (1st generation)": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 320, heightPoints: 568, borderX: 21, borderY: 21),
        "iPhone SE (2nd generation)": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 375, heightPoints: 667, borderX: 21, borderY: 21),
        "iPhone SE (3rd generation)": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 375, heightPoints: 667, borderX: 21, borderY: 21),
        "iPhone X": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 375, heightPoints: 812, borderX: 21, borderY: 21),
        "iPhone XR": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 414, heightPoints: 896, borderX: 21, borderY: 21),
        "iPhone XS": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 375, heightPoints: 812, borderX: 21, borderY: 21),
        "iPhone XS Max": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 414, heightPoints: 896, borderX: 21, borderY: 21),
        "iPhone 11": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 414, heightPoints: 896, borderX: 21, borderY: 21),
        "iPhone 11 Pro": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 375, heightPoints: 812, borderX: 21, borderY: 21),
        "iPhone 11 Pro Max": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 414, heightPoints: 896, borderX: 21, borderY: 21),
        "iPhone 12": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 390, heightPoints: 844, borderX: 21, borderY: 21),
        "iPhone 12 mini": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 375, heightPoints: 812, borderX: 21, borderY: 21),
        "iPhone 12 Pro": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 390, heightPoints: 844, borderX: 21, borderY: 21),
        "iPhone 12 Pro Max": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 428, heightPoints: 926, borderX: 21, borderY: 21),
        "iPhone 13": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 390, heightPoints: 844, borderX: 21, borderY: 21),
        "iPhone 13 mini": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 375, heightPoints: 812, borderX: 21, borderY: 21),
        "iPhone 13 Pro": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 390, heightPoints: 844, borderX: 21, borderY: 21),
        "iPhone 13 Pro Max": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 428, heightPoints: 926, borderX: 21, borderY: 21),
        "iPhone 14": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 390, heightPoints: 844, borderX: 21, borderY: 21),
        "iPhone 14 Plus": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 428, heightPoints: 926, borderX: 21, borderY: 21),
        "iPhone 14 Pro": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 393, heightPoints: 852, borderX: 21, borderY: 21),
        "iPhone 14 Pro Max": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 430, heightPoints: 932, borderX: 21, borderY: 21),
        "iPhone 15": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 393, heightPoints: 852, borderX: 21, borderY: 21),
        "iPhone 15 Plus": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 430, heightPoints: 932, borderX: 21, borderY: 21),
        "iPhone 15 Pro": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 393, heightPoints: 852, borderX: 21, borderY: 21),
        "iPhone 15 Pro Max": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 430, heightPoints: 932, borderX: 21, borderY: 21),
        "iPhone 16": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 393, heightPoints: 852, borderX: 21, borderY: 21),
        "iPhone 16 Plus": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 430, heightPoints: 932, borderX: 21, borderY: 21),
        "iPhone 16 Pro": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 402, heightPoints: 874, borderX: 21, borderY: 14),
        "iPhone 16 Pro Max": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 440, heightPoints: 956, borderX: 21, borderY: 21),
        "iPhone 16e": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 390, heightPoints: 844, borderX: 21, borderY: 21),
        "iPhone 17": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 402, heightPoints: 874, borderX: 20, borderY: 13),
        "iPhone 17 Pro": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 402, heightPoints: 874, borderX: 19, borderY: 18),
        "iPhone 17 Pro Max": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 440, heightPoints: 956, borderX: 16, borderY: 10),
        "iPhone Air": .init(toolbarHeight: 40, toolbarOffset: 7, widthPoints: 420, heightPoints: 912, borderX: 21, borderY: 21),
    ]

    /// Get config for a device by name (fuzzy matching)
    static func config(for deviceName: String?) -> SimulatorDeviceConfig {
        guard let name = deviceName else { return defaultConfig }

        // Exact match first
        if let config = devices[name] { return config }

        // Fuzzy match — sort by key length descending so more specific names match first
        // e.g. "iPhone 16 Pro" matches before "iPhone 16"
        let sorted = devices.keys.sorted { $0.count > $1.count }
        for key in sorted {
            if name.contains(key) { return devices[key]! }
        }

        return defaultConfig
    }

    /// Compute the crop rect in normalized UV coordinates for the captured frame.
    /// The captured frame includes: toolbar + bezel + screen + bezel
    /// We want to extract just the screen area.
    ///
    /// Returns (x, y, width, height) in 0-1 UV space.
    static func cropRect(config: SimulatorDeviceConfig, frameWidth: Int, frameHeight: Int) -> (x: Double, y: Double, w: Double, h: Double) {
        let fw = Double(frameWidth)
        let fh = Double(frameHeight)

        // Frame is captured at 2x retina, config values are in 1x points
        let scale = 2.0

        // Toolbar is at the top of the capture
        let toolbarPx = (config.toolbarHeight + config.toolbarOffset) * scale
        // Bezel around the screen
        let borderXPx = config.borderX * scale
        let borderYPx = config.borderY * scale

        // Screen content starts after toolbar + top bezel
        let screenX = borderXPx
        let screenY = toolbarPx + borderYPx
        let screenW = fw - borderXPx * 2
        let screenH = fh - toolbarPx - borderYPx * 2

        return (
            x: screenX / fw,
            y: screenY / fh,
            w: screenW / fw,
            h: screenH / fh
        )
    }

    /// Convert view coordinates (0..viewW, 0..viewH) to simulator points
    static func viewToSimulatorCoords(
        viewX: Double, viewY: Double,
        viewWidth: Double, viewHeight: Double,
        config: SimulatorDeviceConfig
    ) -> (x: Double, y: Double) {
        // View shows just the cropped screen content, mapped to device points
        let simX = (viewX / viewWidth) * config.widthPoints
        let simY = (viewY / viewHeight) * config.heightPoints
        return (x: simX, y: simY)
    }
}

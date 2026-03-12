import Foundation
import ScreenCaptureKit
import CoreVideo
import CoreMedia
import os

private let logger = Logger(subsystem: "com.blitz.macos", category: "SimulatorCapture")

/// ScreenCaptureKit-based simulator frame capture
final class SimulatorCaptureService: NSObject, @unchecked Sendable {
    private var stream: SCStream?
    private var streamOutput: StreamOutputHandler?
    private var currentWindow: SCWindow?
    private var resizeTimer: Timer?

    /// Protects _latestFrame against concurrent read (main thread) / write (capture queue)
    private let frameLock = NSLock()
    private var _latestFrame: CVPixelBuffer?

    /// Latest captured frame — read by MetalRenderer on the main thread
    var latestFrame: CVPixelBuffer? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return _latestFrame
    }
    private(set) var frameSize: CGSize = .zero
    private(set) var isCapturing = false
    private(set) var frameCount: Int = 0

    /// Callback when a new frame arrives
    var onFrame: ((CVPixelBuffer) -> Void)?

    private var skipFrameCount = 0
    private var configuredFPS: Int = 30

    private let simulatorBundleIDs = [
        "com.apple.iphonesimulator",
        "com.apple.CoreSimulator.SimulatorTrampoline"
    ]

    /// Search an already-fetched SCShareableContent for the simulator window.
    private func findSimulatorWindow(in content: SCShareableContent) -> SCWindow? {
        for window in content.windows {
            guard let app = window.owningApplication else { continue }
            if simulatorBundleIDs.contains(app.bundleIdentifier),
               window.frame.width >= 200, window.frame.height >= 300 {
                logger.info("Found simulator window: \(Int(window.frame.width))x\(Int(window.frame.height))")
                return window
            }
        }
        return nil
    }

    /// Start capturing the simulator window.
    /// Calls SCShareableContent exactly ONCE. If the window isn't visible yet,
    /// retries the query up to 10 times (1s apart).
    func startCapture(fps: Int = 30, retryForWindow: Bool = true) async throws {
        guard !isCapturing else {
            logger.warning("Already capturing")
            return
        }

        logger.info("Starting capture at \(fps) FPS...")
        self.configuredFPS = fps

        // Step 1: Query SCShareableContent ONCE to get permission sorted out.
        // If this throws, it's a permission error — bail immediately, no retry.
        let initialContent: SCShareableContent
        do {
            initialContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            logger.error("SCShareableContent failed: \(error.localizedDescription)")
            throw CaptureError.screenRecordingDenied(error.localizedDescription)
        }

        // Step 2: Look for the simulator window. If not found, retry (re-querying
        // SCShareableContent is safe AFTER the first successful call — TCC won't re-prompt
        // for the same process once granted).
        var window = findSimulatorWindow(in: initialContent)

        if window == nil && retryForWindow {
            let maxAttempts = 10
            for attempt in 1...maxAttempts {
                logger.info("Simulator window not found, retrying... (\(attempt)/\(maxAttempts))")
                try await Task.sleep(for: .seconds(1))

                if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) {
                    window = findSimulatorWindow(in: content)
                    if window != nil { break }
                }
            }
        }

        guard let window else {
            throw CaptureError.simulatorWindowNotFound
        }

        currentWindow = window

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()

        let scale: CGFloat = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false

        logger.info("Stream config: \(config.width)x\(config.height) BGRA")

        let handler = StreamOutputHandler(service: self)
        self.streamOutput = handler

        let stream = SCStream(filter: filter, configuration: config, delegate: handler)
        try stream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))

        do {
            try await stream.startCapture()
        } catch {
            logger.error("startCapture failed: \(error.localizedDescription)")
            throw CaptureError.captureStartFailed(error.localizedDescription)
        }

        self.stream = stream
        self.isCapturing = true
        self.skipFrameCount = 0
        self.frameCount = 0
        self.frameSize = CGSize(width: config.width, height: config.height)

        logger.info("Capture started successfully")

        // Poll for window resize every second
        await MainActor.run {
            self.resizeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { await self?.checkForResize() }
            }
        }
    }

    /// Stop capturing
    func stopCapture() async {
        logger.info("Stopping capture (total frames: \(self.frameCount))")

        await MainActor.run {
            resizeTimer?.invalidate()
            resizeTimer = nil
        }

        if let stream {
            try? await stream.stopCapture()
        }

        stream = nil
        streamOutput = nil
        currentWindow = nil
        isCapturing = false
        clearLatestFrame()
    }

    private func clearLatestFrame() {
        frameLock.lock()
        _latestFrame = nil
        frameLock.unlock()
    }

    /// Check if the simulator window has resized using the stored window reference.
    /// Does NOT re-query SCShareableContent (which would re-trigger TCC prompts).
    private func checkForResize() async {
        guard isCapturing, let window = currentWindow else { return }

        let scale: CGFloat = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
        let newWidth = Int(window.frame.width * scale)
        let newHeight = Int(window.frame.height * scale)

        guard newWidth > 0, newHeight > 0,
              newWidth != Int(frameSize.width) || newHeight != Int(frameSize.height) else { return }

        logger.info("Window resized: \(newWidth)x\(newHeight)")
        let config = SCStreamConfiguration()
        config.width = newWidth
        config.height = newHeight
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuredFPS))
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false

        do {
            try await stream?.updateConfiguration(config)
            frameSize = CGSize(width: newWidth, height: newHeight)
            skipFrameCount = 0
        } catch {
            logger.warning("Failed to update stream config: \(error.localizedDescription)")
        }
    }

    /// Called by StreamOutputHandler when a frame arrives
    fileprivate func handleFrame(_ sampleBuffer: CMSampleBuffer) {
        // Skip first 3 frames (initialization artifacts)
        if skipFrameCount < 3 {
            skipFrameCount += 1
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        frameCount += 1
        if frameCount == 1 {
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            logger.info("First frame received: \(w)x\(h)")
        }

        frameLock.lock()
        _latestFrame = pixelBuffer
        frameLock.unlock()
        onFrame?(pixelBuffer)
    }

    /// Called when the stream encounters an error
    fileprivate func handleStreamError(_ error: Error) {
        logger.error("Stream error: \(error.localizedDescription)")
    }

    enum CaptureError: Error, LocalizedError {
        case simulatorWindowNotFound
        case screenRecordingDenied(String)
        case captureStartFailed(String)

        var errorDescription: String? {
            switch self {
            case .simulatorWindowNotFound:
                return "Could not find iOS Simulator window. Make sure Simulator.app is running."
            case .screenRecordingDenied(let msg):
                return "Screen recording permission denied. Grant access in System Settings → Privacy & Security → Screen Recording. (\(msg))"
            case .captureStartFailed(let msg):
                return "Failed to start capture: \(msg)"
            }
        }
    }
}

/// SCStream output + delegate handler
private final class StreamOutputHandler: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private weak var service: SimulatorCaptureService?

    init(service: SimulatorCaptureService) {
        self.service = service
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        service?.handleFrame(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        service?.handleStreamError(error)
    }
}

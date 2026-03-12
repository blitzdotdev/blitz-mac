import Foundation
import AVFoundation
import CoreMediaIO
import CoreVideo

/// Physical device screen capture via CoreMediaIO + AVCaptureSession
/// Port of src-tauri/src/commands/device_stream.rs
final class DeviceCaptureService: NSObject, @unchecked Sendable {
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private let outputQueue = DispatchQueue(label: "com.blitz.device-capture", qos: .userInteractive)

    private let frameLock = NSLock()
    private var _latestFrame: CVPixelBuffer?

    private(set) var isCapturing = false
    var latestFrame: CVPixelBuffer? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return _latestFrame
    }
    var onFrame: ((CVPixelBuffer) -> Void)?

    private var skipFrameCount = 0
    private var lastFrameTime: Date?
    private var disconnectTimer: Timer?

    /// Enable CoreMediaIO screen capture devices
    static func enableScreenCaptureDevices() {
        var prop = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        var allow: UInt32 = 1
        let size = UInt32(MemoryLayout<UInt32>.size)
        CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &prop, 0, nil, size, &allow
        )

        // Warmup: trigger device enumeration
        _ = AVCaptureDevice.devices()

        // Wait for CoreMediaIO to register devices
        Thread.sleep(forTimeInterval: 1.0)
    }

    /// Find a connected iOS device
    func findDevice(udid: String? = nil) -> AVCaptureDevice? {
        let devices = AVCaptureDevice.devices()

        // Filter out built-in cameras
        let excludePatterns = ["FaceTime", "Built-in", "UVC", "Virtual"]

        return devices.first { device in
            let name = device.localizedName
            let isExcluded = excludePatterns.contains { name.contains($0) }

            if isExcluded { return false }

            if let udid {
                return device.uniqueID == udid
            }

            // Match iOS devices (they show up as screen capture devices)
            return device.hasMediaType(.video)
        }
    }

    /// Start capturing from a physical device
    func startCapture(device: AVCaptureDevice) throws {
        guard !isCapturing else { return }

        let session = AVCaptureSession()

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CaptureError.cannotAddInput
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: outputQueue)

        guard session.canAddOutput(output) else {
            throw CaptureError.cannotAddOutput
        }
        session.addOutput(output)

        session.startRunning()

        self.captureSession = session
        self.videoOutput = output
        self.isCapturing = true
        self.skipFrameCount = 0
    }

    /// Stop capturing
    func stopCapture() {
        captureSession?.stopRunning()
        captureSession = nil
        videoOutput = nil
        isCapturing = false
        frameLock.lock()
        _latestFrame = nil
        frameLock.unlock()
        disconnectTimer?.invalidate()
        disconnectTimer = nil
    }

    /// Check if device is still connected (3-second timeout)
    var isDeviceConnected: Bool {
        guard let lastTime = lastFrameTime else { return false }
        return Date().timeIntervalSince(lastTime) < 3.0
    }

    enum CaptureError: Error, LocalizedError {
        case cannotAddInput
        case cannotAddOutput

        var errorDescription: String? {
            switch self {
            case .cannotAddInput: return "Cannot add capture input"
            case .cannotAddOutput: return "Cannot add capture output"
            }
        }
    }
}

extension DeviceCaptureService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Skip first 3 frames
        if skipFrameCount < 3 {
            skipFrameCount += 1
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lastFrameTime = Date()
        frameLock.lock()
        _latestFrame = pixelBuffer
        frameLock.unlock()
        onFrame?(pixelBuffer)
    }
}

import Foundation
import ScreenCaptureKit

/// Manages system permissions (screen recording, accessibility, camera)
@MainActor
@Observable
final class PermissionService {
    var screenRecordingGranted = false
    var accessibilityGranted = false

    /// Check current permission status
    func checkPermissions() {
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        accessibilityGranted = AXIsProcessTrusted()
    }

    /// Request screen recording permission by triggering SCShareableContent
    /// (This triggers the TCC prompt properly, unlike CGRequestScreenCaptureAccess)
    func requestScreenRecording() async {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            screenRecordingGranted = true
        } catch {
            screenRecordingGranted = false
        }
    }

    /// Request accessibility permission
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
    }
}

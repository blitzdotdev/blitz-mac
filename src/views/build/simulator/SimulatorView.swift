import SwiftUI
import MetalKit
import SwiftTerm

/// Main Build tab view — simulator frame display + touch interaction
struct SimulatorView: View {
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow

    private var stream: SimulatorStreamManager { appState.simulatorStream }
    @State private var deviceInteraction = DeviceInteractionService()
    @State private var keyMonitor: Any?

    /// Get the device config for the currently booted simulator
    private var deviceConfig: SimulatorDeviceConfig {
        let name = appState.simulatorManager.simulators
            .first(where: { $0.udid == appState.simulatorManager.bootedDeviceId })?
            .name
        return SimulatorConfigDatabase.config(for: name)
    }

    /// Current frame dimensions from the capture (pixels)
    private var frameSize: CGSize { stream.captureService.frameSize }

    /// Compute the crop rect from device config + current frame size.
    /// Only crops the toolbar — bezels remain visible (matches blitz-cn).
    private var cropRect: (x: Double, y: Double, w: Double, h: Double) {
        let size = frameSize
        guard size.width > 0, size.height > 0 else {
            return (0, 0, 1, 1)
        }
        return SimulatorConfigDatabase.cropRect(
            config: deviceConfig,
            frameWidth: Int(size.width),
            frameHeight: Int(size.height)
        )
    }

    /// Aspect ratio of the crop region (full width × height-minus-toolbar).
    private var cropAspectRatio: CGFloat {
        let size = frameSize
        guard size.width > 0, size.height > 0 else {
            return deviceConfig.widthPoints / deviceConfig.heightPoints
        }
        let crop = cropRect
        let cropW = crop.w * size.width
        let cropH = crop.h * size.height
        guard cropH > 0 else {
            return deviceConfig.widthPoints / deviceConfig.heightPoints
        }
        return cropW / cropH
    }

    var body: some View {
        VStack(spacing: 0) {
            if let renderer = stream.renderer, stream.isCapturing {
                SimulatorCatPlaygroundView(
                    scene: appState.simulatorCats,
                    phoneAspectRatio: cropAspectRatio,
                    mode: .simulatorStage
                ) {
                    ZStack {
                        MetalFrameView(
                            renderer: renderer,
                            captureService: stream.captureService,
                            cursor: nil,
                            cropRect: cropRect
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 32))

                        TouchOverlayView(
                            deviceConfig: deviceConfig,
                            frameWidth: Int(frameSize.width),
                            frameHeight: Int(frameSize.height),
                            onTap: { x, y in
                                Task { try? await handleTap(x: x, y: y) }
                            },
                            onSwipe: { fx, fy, tx, ty, duration, delta in
                                Task {
                                    try? await handleSwipe(
                                        fromX: fx,
                                        fromY: fy,
                                        toX: tx,
                                        toY: ty,
                                        duration: duration,
                                        delta: delta
                                    )
                                }
                            }
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 32))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 32))
                    .overlay(
                        RoundedRectangle(cornerRadius: 32)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.28), radius: 30, y: 12)
                }
            } else if let errorMessage = stream.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)

                    HStack(spacing: 12) {
                        Button("Open System Settings") {
                            AppRelaunchService.shared.prepareForScreenRecordingPermissionRestart()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                        Button("Retry") {
                            Task {
                                await stream.startStreaming(
                                    bootedDeviceId: appState.simulatorManager.bootedDeviceId,
                                    )
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.simulatorManager.isBooting {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    if let name = appState.simulatorManager.bootingDeviceName {
                        Text("Switching to \(name)...")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Booting simulator...")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "iphone")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)

                    if let statusMessage = stream.statusMessage {
                        ProgressView()
                            .controlSize(.small)
                        Text(statusMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No simulator streaming")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)

                        Button("Start Streaming") {
                            Task {
                                await stream.startStreaming(
                                    bootedDeviceId: appState.simulatorManager.bootedDeviceId,
                                    )
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        }
        .onAppear {
            stream.ensureRenderer()
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                DeviceSelectorView(appState: appState)
            }

            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    Task {
                        guard let udid = appState.simulatorManager.bootedDeviceId else { return }
                        _ = try? await deviceInteraction.execute(.button(.home), udid: udid)
                        appState.simulatorCats.recordButtonPress()
                    }
                }) {
                    Image(systemName: "house")
                        .padding(.horizontal, 4)
                }
                .help("Home button")
            }

            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    appState.simulatorCats.requestFullscreenOnNextOpen()
                    openWindow(id: "cat-playground")
                }) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .padding(.horizontal, 4)
                }
                .help("Open cat-only fullscreen playground")
            }

            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    if stream.isCapturing {
                        Task { await stream.stopStreaming() }
                    } else {
                        Task {
                            await stream.startStreaming(
                                bootedDeviceId: appState.simulatorManager.bootedDeviceId,
                            )
                        }
                    }
                }) {
                    Image(systemName: stream.isCapturing ? "stop.fill" : "play.fill")
                        .padding(.horizontal, 4)
                }
                .help(stream.isCapturing ? "Stop streaming" : "Start streaming")
            }
        }
    }

    private func handleTap(x: Double, y: Double) async throws {
        guard let udid = appState.simulatorManager.bootedDeviceId else { return }
        appState.simulatorCats.recordTap(at: normalizedCatPoint(x: x, y: y))
        _ = try await deviceInteraction.execute(.tap(x: x, y: y), udid: udid)
    }

    private func handleSwipe(fromX: Double, fromY: Double, toX: Double, toY: Double, duration: Double, delta: Int) async throws {
        guard let udid = appState.simulatorManager.bootedDeviceId else { return }
        appState.simulatorCats.recordSwipe(
            from: normalizedCatPoint(x: fromX, y: fromY),
            to: normalizedCatPoint(x: toX, y: toY)
        )
        _ = try await deviceInteraction.execute(
            .swipe(fromX: fromX, fromY: fromY, toX: toX, toY: toY, duration: duration, delta: Double(delta)),
            udid: udid
        )
    }

    private func normalizedCatPoint(x: Double, y: Double) -> CGPoint {
        CGPoint(
            x: CGFloat((x / deviceConfig.widthPoints).clamped(to: 0.08...0.92)),
            y: CGFloat((y / deviceConfig.heightPoints).clamped(to: 0.08...0.92))
        )
    }

    // MARK: - Keyboard Passthrough

    /// HID keycodes for special keys that idb `ui key` accepts
    private static let hidKeycodes: [UInt16: Int] = [
        36: 40,   // Return
        51: 42,   // Backspace/Delete
        48: 43,   // Tab
        53: 41,   // Escape
        123: 80,  // Left arrow
        124: 79,  // Right arrow
        125: 81,  // Down arrow
        126: 82,  // Up arrow
        117: 76,  // Forward Delete
        115: 74,  // Home
        119: 77,  // End
        116: 75,  // Page Up
        121: 78,  // Page Down
        49: 44,   // Space
    ]

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            // Only capture when simulator is streaming and this tab is active
            guard stream.isCapturing,
                  appState.activeTab == .app && appState.activeAppSubTab == .simulator,
                  !appState.ascManager.showAppleIDLogin,
                  let udid = appState.simulatorManager.bootedDeviceId else {
                return event
            }

            // Don't capture if another text-input surface currently owns focus.
            if simulatorKeyPassthroughShouldIgnore(event.window?.firstResponder) {
                return event
            }

            // Ignore modifier-only keys and Cmd-combos (let system handle those)
            if event.modifierFlags.contains(.command) {
                return event
            }

            let interaction = deviceInteraction
            if let hidCode = Self.hidKeycodes[event.keyCode] {
                Task {
                    _ = try? await interaction.execute(.key(.keycode(hidCode)), udid: udid)
                    appState.simulatorCats.recordButtonPress()
                }
                return nil // consumed
            } else if let chars = event.characters, !chars.isEmpty,
                      chars.unicodeScalars.allSatisfy({ !$0.properties.isNoncharacterCodePoint && $0.value >= 0x20 }) {
                Task {
                    _ = try? await interaction.execute(.inputText(chars), udid: udid)
                    appState.simulatorCats.recordButtonPress()
                }
                return nil // consumed
            }

            return event
        }
    }

    private func simulatorKeyPassthroughShouldIgnore(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }

        if responder is NSTextView || responder is NSTextField || responder is TerminalView {
            return true
        }

        var view = responder as? NSView
        while let current = view {
            if current is TerminalView {
                return true
            }
            view = current.superview
        }

        return false
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

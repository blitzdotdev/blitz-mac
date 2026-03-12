import Foundation
import os

private let logger = Logger(subsystem: "com.blitz.macos", category: "SimulatorService")

/// High-level simulator management service
actor SimulatorService {
    private let simctl = SimctlClient()

    /// List all available simulators
    func listDevices() async throws -> [SimctlClient.SimctlDevice] {
        try await simctl.listDevices()
    }

    /// Boot a simulator, then opens Simulator.app to show its window
    func boot(udid: String) async throws {
        logger.info("Booting simulator \(udid)...")

        // Boot the specific device FIRST — before opening Simulator.app,
        // otherwise Simulator.app auto-boots its last-used device.
        do {
            try await simctl.boot(udid: udid)
        } catch {
            // "Unable to boot device in current state: Booted" is not a real error
            if let processError = error as? ProcessRunner.ProcessError,
               processError.stderr.contains("current state: Booted") {
                logger.info("Simulator already booted")
            } else {
                throw error
            }
        }

        // Wait for boot to complete — poll until state is Booted
        logger.info("Waiting for simulator to finish booting...")
        for i in 1...15 {
            let devices = try await simctl.listDevices()
            if let device = devices.first(where: { $0.udid == udid }), device.isBooted {
                logger.info("Simulator booted after \(i)s")
                break
            }
            try await Task.sleep(for: .seconds(1))
        }

        // Open Simulator.app AFTER boot so it shows the correct device window
        // (opening before boot causes it to auto-boot its last-used device)
        try await openSimulatorApp()
    }

    /// Shutdown a simulator
    func shutdown(udid: String) async throws {
        try await simctl.shutdown(udid: udid)
    }

    /// Install an app bundle
    func installApp(udid: String, appPath: String) async throws {
        try await simctl.install(udid: udid, appPath: appPath)
    }

    /// Launch an app by bundle ID
    func launchApp(udid: String, bundleId: String) async throws {
        try await simctl.launch(udid: udid, bundleId: bundleId)
    }

    /// Take a screenshot and save to path
    func screenshot(udid: String, saveTo path: String) async throws {
        try await simctl.screenshot(udid: udid, path: path)
    }

    /// Open the Simulator.app
    func openSimulatorApp() async throws {
        _ = try await ProcessRunner.run("open", arguments: ["-a", "Simulator"])
        // Give it a moment to launch
        try await Task.sleep(for: .milliseconds(500))
    }
}

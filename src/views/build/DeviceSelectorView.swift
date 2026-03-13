import SwiftUI

struct DeviceSelectorView: View {
    @Bindable var appState: AppState

    private var supportedSimulators: [SimulatorInfo] {
        appState.simulatorManager.simulators.filter {
            SimulatorConfigDatabase.isSupported($0.name)
        }
    }

    var body: some View {
        Menu {
            Section("Simulators") {
                ForEach(supportedSimulators) { sim in
                    Button(action: {
                        Task { await selectSimulator(sim) }
                    }) {
                        HStack {
                            Text(sim.name)
                            if sim.udid == appState.simulatorManager.bootedDeviceId {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(appState.simulatorManager.isBooting)
                }

                if supportedSimulators.isEmpty {
                    Text("No supported simulators found")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Button("Refresh Devices") {
                Task { await appState.simulatorManager.loadSimulators() }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "iphone")
                if let bootedId = appState.simulatorManager.bootedDeviceId,
                   let sim = appState.simulatorManager.simulators.first(where: { $0.udid == bootedId }) {
                    Text(sim.name)
                        .font(.system(size: 11))
                } else {
                    Text("Select Device")
                        .font(.system(size: 11))
                }
                if appState.simulatorManager.isBooting {
                    ProgressView()
                        .scaleEffect(0.6)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func selectSimulator(_ sim: SimulatorInfo) async {
        let manager = appState.simulatorManager
        let oldId = manager.bootedDeviceId
        guard sim.udid != oldId else { return }

        manager.isBooting = true
        manager.bootingDeviceName = sim.name
        defer {
            manager.isBooting = false
            manager.bootingDeviceName = nil
        }

        // 1. Stop the current stream
        await appState.simulatorStream.stopStreaming()

        // 2. Shutdown the old simulator
        if let oldId {
            let service = SimulatorService()
            try? await service.shutdown(udid: oldId)
        }

        // 3. Boot the new simulator in background
        if !sim.isBooted {
            let service = SimulatorService()
            do {
                try await service.bootInBackground(udid: sim.udid)
            } catch {
                print("Failed to boot simulator: \(error)")
                return
            }
        }

        // 4. Update state and refresh device list
        manager.bootedDeviceId = sim.udid
        await manager.loadSimulators()

        // 5. Start streaming the new device
        if appState.activeTab == .simulator {
            await appState.simulatorStream.startStreaming(
                bootedDeviceId: sim.udid,
                fps: appState.settingsStore.simulatorFPS
            )
        }
    }
}

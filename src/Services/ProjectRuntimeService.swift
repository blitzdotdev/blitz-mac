import Foundation

/// Orchestrates the full project lifecycle: create → install deps → build → metro → run
actor ProjectRuntimeService {
    private let sidecar: NodeSidecarService
    private let simulatorService: SimulatorService
    private var statusPollingTask: Task<Void, Never>?

    init(sidecar: NodeSidecarService, simulatorService: SimulatorService) {
        self.sidecar = sidecar
        self.simulatorService = simulatorService
    }

    /// Start a project's runtime
    func startRuntime(runtime: ProjectRuntime, simulatorUDID: String?) async {
        // Forward-only status progression
        runtime.updateStatus(.installingDependencies)

        do {
            try await sidecar.startRuntime(projectId: runtime.projectId, simulatorUDID: simulatorUDID)
            startPollingStatus(runtime: runtime)
        } catch {
            runtime.error = error.localizedDescription
            runtime.updateStatus(.error)
        }
    }

    /// Stop a project's runtime
    func stopRuntime(runtime: ProjectRuntime) async {
        statusPollingTask?.cancel()
        statusPollingTask = nil

        do {
            try await sidecar.stopRuntime(projectId: runtime.projectId)
        } catch {
            print("Error stopping runtime: \(error)")
        }

        runtime.updateStatus(.stopped)
    }

    /// Poll the sidecar for runtime status updates
    private func startPollingStatus(runtime: ProjectRuntime) {
        statusPollingTask?.cancel()
        statusPollingTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                    let status = try await sidecar.getRuntimeStatus(projectId: runtime.projectId)

                    // Map sidecar status string to RuntimeStatus
                    if let newStatus = RuntimeStatus(rawValue: status.status) {
                        await MainActor.run {
                            runtime.updateStatus(newStatus)
                            runtime.metroPort = status.metroPort
                            runtime.vitePort = status.vitePort
                            runtime.backendPort = status.backendPort
                        }

                        if newStatus == .running || newStatus == .error || newStatus == .stopped {
                            if let error = status.error {
                                await MainActor.run { runtime.error = error }
                            }
                            break // Stop polling
                        }
                    }
                } catch {
                    if !Task.isCancelled {
                        await MainActor.run {
                            runtime.error = error.localizedDescription
                            runtime.updateStatus(.error)
                        }
                        break
                    }
                }
            }
        }
    }

    /// Reload Metro bundler
    func reloadMetro() async throws {
        try await sidecar.reloadMetro()
    }
}

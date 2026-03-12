import Foundation

/// Forward-only runtime status progression
enum RuntimeStatus: String, Comparable, CaseIterable {
    case idle
    case buildingWarmTemplate = "building_warm_template"
    case installingDependencies = "installing_dependencies"
    case startingIOSBuild = "starting_ios_build"
    case startingMetro = "starting_metro"
    case startingVite = "starting_vite"
    case startingBackend = "starting_backend"
    case running
    case error
    case stopped

    static func < (lhs: RuntimeStatus, rhs: RuntimeStatus) -> Bool {
        guard let li = Self.allCases.firstIndex(of: lhs),
              let ri = Self.allCases.firstIndex(of: rhs) else { return false }
        return li < ri
    }

    var displayName: String {
        switch self {
        case .idle: "Idle"
        case .buildingWarmTemplate: "Building Template..."
        case .installingDependencies: "Installing Dependencies..."
        case .startingIOSBuild: "Building iOS App..."
        case .startingMetro: "Starting Metro..."
        case .startingVite: "Starting Vite..."
        case .startingBackend: "Starting Backend..."
        case .running: "Running"
        case .error: "Error"
        case .stopped: "Stopped"
        }
    }

    var isActive: Bool {
        switch self {
        case .idle, .error, .stopped: false
        default: true
        }
    }
}

@Observable
final class ProjectRuntime {
    let projectId: String
    private(set) var status: RuntimeStatus = .idle
    var error: String?
    var metroPort: Int?
    var vitePort: Int?
    var backendPort: Int?

    init(projectId: String) {
        self.projectId = projectId
    }

    /// Forward-only status update — can only advance or go to error/stopped
    func updateStatus(_ newStatus: RuntimeStatus) {
        if newStatus == .error || newStatus == .stopped || newStatus > status {
            status = newStatus
        }
    }
}

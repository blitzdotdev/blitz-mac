import Foundation

/// Protocol types for communication with the Node.js sidecar over Unix domain socket

// MARK: - Requests

struct CreateProjectRequest: Codable, Sendable {
    let name: String
    let type: ProjectType
    let template: String?

    init(name: String, type: ProjectType, template: String? = nil) {
        self.name = name
        self.type = type
        self.template = template
    }
}

struct ImportProjectRequest: Codable, Sendable {
    let path: String
    let type: ProjectType

    init(path: String, type: ProjectType) {
        self.path = path
        self.type = type
    }
}

struct StartRuntimeRequest: Codable, Sendable {
    let projectId: String
    let simulatorUDID: String?

    init(projectId: String, simulatorUDID: String? = nil) {
        self.projectId = projectId
        self.simulatorUDID = simulatorUDID
    }
}

// MARK: - Responses

struct CreateProjectResponse: Codable, Sendable {
    let projectId: String
    let path: String
}

struct RuntimeStatusResponse: Codable, Sendable {
    let status: String
    let error: String?
    let metroPort: Int?
    let vitePort: Int?
    let backendPort: Int?
}

struct BackendLogsResponse: Codable, Sendable {
    let logs: [String]
}

// MARK: - Sidecar Routes

enum SidecarRoute {
    case createProject
    case importProject
    case startRuntime(projectId: String)
    case runtimeStatus(projectId: String)
    case stopRuntime(projectId: String)
    case reloadMetro
    case backendLogs(projectId: String)

    var method: String {
        switch self {
        case .createProject, .importProject, .startRuntime, .stopRuntime, .reloadMetro:
            return "POST"
        case .runtimeStatus, .backendLogs:
            return "GET"
        }
    }

    var path: String {
        switch self {
        case .createProject:
            return "/projects"
        case .importProject:
            return "/projects/import"
        case .startRuntime(let id):
            return "/projects/\(id)/runtime"
        case .runtimeStatus(let id):
            return "/projects/\(id)/runtime-status"
        case .stopRuntime(let id):
            return "/projects/\(id)/runtime/stop"
        case .reloadMetro:
            return "/simulator/reload"
        case .backendLogs(let id):
            return "/projects/\(id)/backend-logs"
        }
    }
}

import Foundation

private struct AnalyticsConfiguration {
    let endpointURL: URL
    let authToken: String
    let appVersion: String
    let osVersion: String

    static func current() -> AnalyticsConfiguration? {
        guard let info = Bundle.main.infoDictionary else { return nil }

        let endpoint = (info["BlitzAnalyticsEndpoint"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let token = (info["BlitzAnalyticsToken"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let endpoint, !endpoint.isEmpty,
              let token, !token.isEmpty,
              let endpointURL = URL(string: endpoint) else {
            return nil
        }

        let appVersion = (info["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "dev"

        return AnalyticsConfiguration(
            endpointURL: endpointURL,
            authToken: token,
            appVersion: appVersion,
            osVersion: operatingSystemVersionString()
        )
    }

    private static func operatingSystemVersionString() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

private enum AnalyticsIdentityStore {
    static func deviceID() -> String? {
        let fm = FileManager.default
        let url = BlitzPaths.analyticsDeviceID

        if let existing = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }

        let identifier = UUID().uuidString
        do {
            try fm.createDirectory(at: BlitzPaths.analytics, withIntermediateDirectories: true)
            try identifier.write(to: url, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return identifier
        } catch {
            return nil
        }
    }
}

private struct AnalyticsEventPayload: Encodable {
    let eventID: String
    let clientAt: String
    let deviceID: String
    let appVersion: String
    let osVersion: String
    let eventName: String
    let source: String?
    let commandType: String?
    let projectType: String?
    let success: Bool?
    let durationMS: Int?

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case clientAt = "client_at"
        case deviceID = "device_id"
        case appVersion = "app_version"
        case osVersion = "os_version"
        case eventName = "event_name"
        case source
        case commandType = "command_type"
        case projectType = "project_type"
        case success
        case durationMS = "duration_ms"
    }
}

enum AnalyticsEventSource: String {
    case blitzManaged = "blitz_managed"
    case agentDirect = "agent_direct"
}

enum AnalyticsService {
    @TaskLocal static var currentMCPToolCommandType: String?

    private static let session = URLSession.shared
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func agentSessionEnvironment() -> [String: String] {
        guard let configuration = AnalyticsConfiguration.current(),
              let deviceID = AnalyticsIdentityStore.deviceID() else {
            return [:]
        }

        return [
            "BLITZ_AGENT_SESSION": "1",
            "BLITZ_ANALYTICS_ENDPOINT": configuration.endpointURL.absoluteString,
            "BLITZ_ANALYTICS_TOKEN": configuration.authToken,
            "BLITZ_ANALYTICS_DEVICE_ID": deviceID,
            "BLITZ_ANALYTICS_APP_VERSION": configuration.appVersion,
            "BLITZ_ANALYTICS_OS_VERSION": configuration.osVersion,
        ]
    }

    static func agentSessionExportCommands() -> [String] {
        agentSessionEnvironment()
            .sorted { $0.key < $1.key }
            .map { key, value in
                "export \(key)=\(shellQuote(value))"
            }
    }

    static func trackAppLaunch() {
        track(
            eventName: "app_launch",
            source: nil,
            commandType: nil,
            projectType: nil,
            success: nil,
            durationMS: nil
        )
    }

    static func trackProjectInventory(projectType: ProjectType) {
        track(
            eventName: "project_inventory",
            source: nil,
            commandType: nil,
            projectType: projectType.rawValue,
            success: nil,
            durationMS: nil
        )
    }

    static func trackProjectCreate(projectType: ProjectType) {
        track(
            eventName: "project_create",
            source: nil,
            commandType: nil,
            projectType: projectType.rawValue,
            success: nil,
            durationMS: nil
        )
    }

    static func trackProjectImport(projectType: ProjectType) {
        track(
            eventName: "project_import",
            source: nil,
            commandType: nil,
            projectType: projectType.rawValue,
            success: nil,
            durationMS: nil
        )
    }

    static func trackBlitzManagedASCUsage(
        commandType: String,
        success: Bool,
        startedAt: Date
    ) {
        if currentMCPToolCommandType != nil {
            return
        }

        trackASCUsage(
            source: .blitzManaged,
            commandType: commandType,
            success: success,
            startedAt: startedAt
        )
    }

    static func withMCPToolContext<T>(
        commandType: String,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await $currentMCPToolCommandType.withValue(commandType) {
            try await operation()
        }
    }

    static func trackBlitzManagedMCPToolStart(commandType: String) {
        trackMCPToolStart(source: .blitzManaged, commandType: commandType)
    }

    static func trackBlitzManagedMCPToolCompletion(
        commandType: String,
        success: Bool,
        startedAt: Date
    ) {
        trackMCPToolCompletion(
            source: .blitzManaged,
            commandType: commandType,
            success: success,
            startedAt: startedAt
        )
    }

    static func trackASCUsage(
        source: AnalyticsEventSource,
        commandType: String,
        success: Bool,
        startedAt: Date
    ) {
        trackMCPToolCompletion(
            source: source,
            commandType: commandType,
            success: success,
            startedAt: startedAt
        )
    }

    private static func trackMCPToolStart(
        source: AnalyticsEventSource,
        commandType: String
    ) {
        track(
            eventName: "asc_usage",
            source: source.rawValue,
            commandType: commandType,
            projectType: nil,
            success: nil,
            durationMS: nil
        )
    }

    private static func trackMCPToolCompletion(
        source: AnalyticsEventSource,
        commandType: String,
        success: Bool,
        startedAt: Date
    ) {
        let durationMS = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
        track(
            eventName: "asc_usage",
            source: source.rawValue,
            commandType: commandType,
            projectType: nil,
            success: success,
            durationMS: durationMS
        )
    }

    private static func track(
        eventName: String,
        source: String?,
        commandType: String?,
        projectType: String?,
        success: Bool?,
        durationMS: Int?
    ) {
        guard let configuration = AnalyticsConfiguration.current(),
              let deviceID = AnalyticsIdentityStore.deviceID() else {
            return
        }

        let payload = AnalyticsEventPayload(
            eventID: UUID().uuidString,
            clientAt: formatter.string(from: Date()),
            deviceID: deviceID,
            appVersion: configuration.appVersion,
            osVersion: configuration.osVersion,
            eventName: eventName,
            source: source,
            commandType: commandType,
            projectType: projectType,
            success: success,
            durationMS: durationMS
        )

        Task.detached(priority: .utility) {
            await post(payload, configuration: configuration)
        }
    }

    private static func post(
        _ payload: AnalyticsEventPayload,
        configuration: AnalyticsConfiguration
    ) async {
        guard let body = try? encoder.encode(payload) else { return }

        var request = URLRequest(url: configuration.endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.authToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return
            }
        } catch {
            return
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

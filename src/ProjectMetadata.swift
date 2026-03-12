import Foundation

/// Represents the `.blitz/project.json` metadata file
struct BlitzProjectMetadata: Codable, Sendable {
    var name: String
    var type: ProjectType
    var bundleIdentifier: String?
    var createdAt: Date?
    var lastOpenedAt: Date?
    var simulatorUDID: String?
    var buildSettings: BuildSettings?
    var teamId: String?

    init(
        name: String,
        type: ProjectType,
        bundleIdentifier: String? = nil,
        createdAt: Date? = nil,
        lastOpenedAt: Date? = nil,
        simulatorUDID: String? = nil,
        buildSettings: BuildSettings? = nil,
        teamId: String? = nil
    ) {
        self.name = name
        self.type = type
        self.bundleIdentifier = bundleIdentifier
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.simulatorUDID = simulatorUDID
        self.buildSettings = buildSettings
        self.teamId = teamId
    }
}

enum ProjectType: String, Codable, Sendable, CaseIterable {
    case blitz
    case reactNative = "react-native"
    case swift
    case flutter
}

struct BuildSettings: Codable, Sendable {
    var scheme: String?
    var configuration: String?
    var destination: String?

    init(scheme: String? = nil, configuration: String? = nil, destination: String? = nil) {
        self.scheme = scheme
        self.configuration = configuration
        self.destination = destination
    }
}

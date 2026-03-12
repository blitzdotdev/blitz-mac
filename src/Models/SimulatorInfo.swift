import Foundation

struct SimulatorInfo: Identifiable, Hashable {
    let udid: String
    let name: String
    let state: String
    let deviceTypeIdentifier: String?
    let lastBootedAt: String?

    var id: String { udid }
    var isBooted: Bool { state == "Booted" }

    var displayName: String {
        // Extract device type from identifier like "com.apple.CoreSimulator.SimDeviceType.iPhone-16"
        if let typeId = deviceTypeIdentifier {
            let components = typeId.split(separator: ".")
            if let last = components.last {
                return String(last).replacingOccurrences(of: "-", with: " ")
            }
        }
        return name
    }
}

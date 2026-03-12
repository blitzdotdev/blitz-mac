import Foundation

struct PhysicalDevice: Identifiable, Hashable {
    let udid: String
    let name: String
    let modelName: String
    let osVersion: String
    let connectionType: ConnectionType

    var id: String { udid }

    enum ConnectionType: String, Codable {
        case usb
        case wifi
    }
}

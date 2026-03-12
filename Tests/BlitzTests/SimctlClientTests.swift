import Testing
@testable import Blitz

@Test func testParseDeviceList() throws {
    let json = """
    {
      "devices": {
        "com.apple.CoreSimulator.SimRuntime.iOS-17-5": [
          {
            "udid": "AAAA-BBBB-CCCC",
            "name": "iPhone 15 Pro",
            "state": "Booted",
            "isAvailable": true,
            "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-15-Pro"
          },
          {
            "udid": "DDDD-EEEE-FFFF",
            "name": "iPhone 15",
            "state": "Shutdown",
            "isAvailable": true,
            "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-15"
          }
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-16-4": [
          {
            "udid": "1111-2222-3333",
            "name": "iPhone 14",
            "state": "Shutdown",
            "isAvailable": false,
            "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-14"
          }
        ]
      }
    }
    """.data(using: .utf8)!

    let client = SimctlClient()
    let devices = try client.parseDeviceList(json: json)

    // Should only include available devices (2 out of 3)
    #expect(devices.count == 2)

    // Should be sorted by name
    #expect(devices[0].name == "iPhone 15")
    #expect(devices[1].name == "iPhone 15 Pro")

    // Check booted state
    #expect(devices[1].isBooted == true)
    #expect(devices[0].isBooted == false)
}

import Foundation
import Testing
@testable import Blitz

@Test func testASCAuthBridgeWritesManagedConfigForAgentSessions() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("asc-auth-bridge-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }

    let bundledASCD = root.appendingPathComponent("Blitz.app/Contents/Helpers/ascd")
    try fileManager.createDirectory(
        at: bundledASCD.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try "#!/bin/sh\nexit 0\n".write(to: bundledASCD, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledASCD.path)

    let bridge = ASCAuthBridge(
        blitzRoot: root,
        fileManager: fileManager,
        bundledASCDPathProvider: { bundledASCD.path }
    )
    let credentials = ASCCredentials(
        issuerId: "ISSUER-123",
        keyId: "KEY-123",
        privateKey: """
        -----BEGIN PRIVATE KEY-----
        TESTKEY
        -----END PRIVATE KEY-----
        """
    )

    try bridge.syncCredentials(credentials)

    let configData = try Data(contentsOf: bridge.configURL)
    let configJSON = try JSONSerialization.jsonObject(with: configData) as? [String: Any]

    #expect(configJSON?["default_key_name"] as? String == "BlitzKey")
    #expect(configJSON?["key_id"] as? String == "KEY-123")
    #expect(configJSON?["issuer_id"] as? String == "ISSUER-123")
    #expect(configJSON?["private_key_path"] as? String == bridge.privateKeyURL.path)

    let keys = configJSON?["keys"] as? [[String: Any]]
    #expect(keys?.count == 1)
    #expect(keys?.first?["name"] as? String == "BlitzKey")

    let persistedPrivateKey = try String(contentsOf: bridge.privateKeyURL, encoding: .utf8)
    #expect(persistedPrivateKey.contains("BEGIN PRIVATE KEY"))

    let managedLaunchPath = root.appendingPathComponent("projects/demo").path
    let env = bridge.environmentOverrides(forLaunchPath: managedLaunchPath)
    #expect(env["PATH"]?.hasPrefix(bridge.binDirectory.path + ":") == true)
    #expect(FileManager.default.isExecutableFile(atPath: bridge.ascWrapperURL.path))
    #expect(FileManager.default.isExecutableFile(atPath: bridge.ascdShimURL.path))

    let wrapper = try String(contentsOf: bridge.ascWrapperURL, encoding: .utf8)
    #expect(wrapper.contains("__ascd_run_cli__"))
    #expect(wrapper.contains("ASC_CONFIG_PATH"))
    #expect(wrapper.contains(bridge.configURL.path))
    #expect(wrapper.contains("${SELF_DIR}/ascd"))

    let shellExports = bridge.shellExportCommands(forLaunchPath: managedLaunchPath)
    #expect(shellExports.contains { $0.contains("export PATH=") && $0.contains(bridge.binDirectory.path) })
    #expect(shellExports.count == 1)

    let unrelatedEnv = bridge.environmentOverrides(forLaunchPath: "/tmp/not-managed")
    #expect(unrelatedEnv.isEmpty)
}

@Test func testASCWebSessionStoreMatchesASCCacheShapeAndPreservesSessions() throws {
    let firstSession = IrisSession(
        cookies: [
            .init(name: "DES123", value: "alpha", domain: ".apple.com", path: "/"),
            .init(name: "itctx", value: "beta", domain: ".appstoreconnect.apple.com", path: "/"),
        ],
        email: "first@example.com",
        capturedAt: Date(timeIntervalSince1970: 1)
    )
    let secondSession = IrisSession(
        cookies: [
            .init(name: "myacinfo", value: "gamma", domain: ".apple.com", path: "/"),
        ],
        email: "second@example.com",
        capturedAt: Date(timeIntervalSince1970: 2)
    )

    let firstData = try ASCWebSessionStore.mergedData(
        storing: firstSession,
        into: nil,
        now: Date(timeIntervalSince1970: 10)
    )
    let mergedData = try ASCWebSessionStore.mergedData(
        storing: secondSession,
        into: firstData,
        now: Date(timeIntervalSince1970: 20)
    )

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let mergedStore = try decoder.decode(ASCWebSessionStore.self, from: mergedData)

    #expect(mergedStore.version == 1)
    #expect(mergedStore.sessions.count == 2)
    #expect(mergedStore.lastKey != nil)

    let storedEmails = Set(mergedStore.sessions.values.compactMap(\.userEmail))
    #expect(storedEmails == Set(["first@example.com", "second@example.com"]))

    let firstStoredSession = mergedStore.sessions.values.first { $0.userEmail == "first@example.com" }
    #expect(firstStoredSession?.cookies["https://appstoreconnect.apple.com/"]?.count == 2)
    #expect(firstStoredSession?.cookies["https://idmsa.apple.com/"]?.count == 1)
    #expect(firstStoredSession?.cookies["https://gsa.apple.com/"]?.count == 1)

    let removedData = try ASCWebSessionStore.removingSession(
        email: "second@example.com",
        from: mergedData
    )
    #expect(removedData != nil)

    let removedStore = try decoder.decode(ASCWebSessionStore.self, from: try #require(removedData))
    #expect(removedStore.sessions.count == 1)
    #expect(removedStore.sessions.values.first?.userEmail == "first@example.com")
    #expect(removedStore.lastKey == removedStore.sessions.keys.first)
}

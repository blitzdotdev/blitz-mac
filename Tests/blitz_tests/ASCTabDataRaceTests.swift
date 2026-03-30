import Foundation
import Testing
@testable import Blitz

@MainActor
@Test func fetchTabDataDoesNotSurfaceNotFoundWhileAppLookupIsStillRunning() async {
    let manager = ASCManager()
    let credentials = ASCCredentials(issuerId: "issuer", keyId: "key", privateKey: "private")
    manager.credentials = credentials
    manager.service = AppStoreConnectService(credentials: credentials)
    manager.isLoadingApp = true
    manager.app = nil

    await manager.fetchTabData(.monetization)

    #expect(manager.tabError[.monetization] == nil)
    #expect(manager.isLoadingTab[.monetization] != true)
    #expect(!manager.loadedTabs.contains(.monetization))
}

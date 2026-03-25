import Foundation
import Testing
@testable import Blitz

@Test @MainActor func testAppUpdateInstallScriptVerifiesSignatureAndFailsOnScriptErrors() {
    let zipPath = URL(fileURLWithPath: "/tmp/Blitz.app.zip")
    let script = AutoUpdateManager.appUpdateInstallScript(zipPath: zipPath)

    #expect(script.contains("/usr/bin/codesign --verify --deep --strict"))
    #expect(script.contains("/usr/sbin/spctl --assess --verbose=4"))
    #expect(script.contains("CFBundleIdentifier"))
    #expect(script.contains("Contents/Helpers/ascd"))
    #expect(script.contains("BLITZ_UPDATE_CONTEXT='auto-update'"))
    #expect(!script.contains("PREINSTALL\\\" '' '' '/' >> \\\"$UPDATE_LOG\\\" 2>&1 || true"))
    #expect(!script.contains("POSTINSTALL\\\" '' '' '/' >> \\\"$UPDATE_LOG\\\" 2>&1 || true"))
}

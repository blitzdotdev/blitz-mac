import Testing
@testable import Blitz

@Test func processOutputCollectorPrioritizesAppIconFailures() {
    let collector = ProcessOutputCollector(maxStoredLines: 40, maxSummaryLines: 12)

    collector.appendStdout("CompileAssetCatalogVariant thinned /tmp/Assets.car")
    collector.appendStderr("/tmp/App.xcassets: error: The app icon set named \"AppIcon\" did not have any applicable content.")
    collector.appendStdout("** ARCHIVE FAILED **")

    let summary = collector.summary

    #expect(summary.contains("CompileAssetCatalogVariant"))
    #expect(summary.contains("app icon set named \"AppIcon\""))
}

@Test func artifactMetadataParsesBuildAndVersionFromInfoPlist() {
    let plistXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleShortVersionString</key>
        <string>1.0</string>
        <key>CFBundleVersion</key>
        <string>42</string>
        <key>ITSAppUsesNonExemptEncryption</key>
        <false/>
    </dict>
    </plist>
    """

    let metadata = MCPExecutor.artifactMetadata(fromPlistXML: plistXML)

    #expect(metadata?.shortVersion == "1.0")
    #expect(metadata?.buildNumber == "42")
    #expect(metadata?.hasEncryptionDeclaration == true)
}

@Test func buildUploadProcessingHintDecodesKnownAppIconErrorCodes() {
    let hint = MCPExecutor.buildUploadProcessingHint(codes: ["90023", "90713", "90022"])

    #expect(hint?.contains("app icon payload") == true)
    #expect(hint?.contains("1024x1024 App Store icon") == true)
}

@Test func buildsUploadCommandArgumentsUseHelperUploadPath() {
    let args = BuildPipelineService.buildsUploadCommandArguments(
        appId: "6761669298",
        artifactPath: "/tmp/NotesApp.ipa",
        platform: .iOS,
        skipPolling: true
    )

    #expect(Array(args.prefix(3)) == ["builds", "upload", "--app"])
    #expect(args.contains("--ipa"))
    #expect(args.contains("--verify-timeout"))
    #expect(!args.contains("altool"))
}

@Test func validatedBuildUploadCLIResultRejectsUnuploadedReservations() {
    let stdout = """
    {"uploadId":"upload-1","fileId":"file-1","uploaded":false}
    """

    do {
        _ = try BuildPipelineService.validatedBuildUploadCLIResult(from: stdout)
        Issue.record("Expected helper upload validation to reject an unuploaded reservation")
    } catch {
        #expect(error.localizedDescription.contains("was not marked uploaded"))
    }
}

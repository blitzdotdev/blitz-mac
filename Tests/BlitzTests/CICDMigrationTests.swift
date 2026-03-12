import Testing
import Foundation
@testable import Blitz

// ── CI/CD Migration: Swift-level tests ───────────────────────────────────────

@Suite("CI/CD Migration — source contract tests")
struct CICDMigrationTests {

    // ── NodeSidecarService source verification ────────────────────────────────

    /// Verifies NodeSidecarService uses BlitzPaths.nodeRuntime for the managed node path.
    @Test("NodeSidecarService uses BlitzPaths.nodeRuntime in node candidates")
    func nodeSidecarIncludesBlitzNodeRuntime() throws {
        let source = try sidecarServiceSource()
        #expect(source.contains("BlitzPaths.nodeRuntime"),
            "Expected BlitzPaths.nodeRuntime in node search candidates")
    }

    /// Verifies the BlitzPaths node-runtime path is checked *before* system paths.
    @Test("BlitzPaths.nodeRuntime is checked before /usr/local/bin/node")
    func nodeRuntimePathHasPriority() throws {
        let source = try sidecarServiceSource()
        let nodeRuntimeRange = try #require(source.range(of: "BlitzPaths.nodeRuntime"))
        let usrLocalRange    = try #require(source.range(of: "/usr/local/bin/node"))
        #expect(nodeRuntimeRange.lowerBound < usrLocalRange.lowerBound,
            "BlitzPaths.nodeRuntime should appear before /usr/local/bin/node in the candidates list")
    }

    /// Confirms no hardcoded "~" paths are used (BlitzPaths handles home directory resolution).
    @Test("NodeSidecarService does not use hardcoded ~ paths")
    func nodeRuntimeNoHardcodedTilde() throws {
        let source = try sidecarServiceSource()
        #expect(!source.contains("\"~/"),
            "Should not use literal '~/' in Swift string — use BlitzPaths instead")
    }

    // ── SidecarProtocol ──────────────────────────────────────────────────────

    @Test("SidecarRoute.createProject path is /projects")
    func sidecarCreateProjectPath() {
        #expect(SidecarRoute.createProject.path == "/projects")
    }

    @Test("SidecarRoute.importProject path is /projects/import")
    func sidecarImportProjectPath() {
        #expect(SidecarRoute.importProject.path == "/projects/import")
    }

    @Test("SidecarRoute.startRuntime path is /projects/{id}/runtime")
    func sidecarStartRuntimePath() {
        #expect(SidecarRoute.startRuntime(projectId: "abc").path == "/projects/abc/runtime")
    }

    @Test("SidecarRoute.reloadMetro path is /simulator/reload")
    func sidecarReloadMetroPath() {
        #expect(SidecarRoute.reloadMetro.path == "/simulator/reload")
    }

    @Test("SidecarRoute POST methods are correct")
    func sidecarPostMethods() {
        #expect(SidecarRoute.createProject.method == "POST")
        #expect(SidecarRoute.importProject.method  == "POST")
        #expect(SidecarRoute.reloadMetro.method    == "POST")
    }

    @Test("SidecarRoute GET methods are correct")
    func sidecarGetMethods() {
        #expect(SidecarRoute.runtimeStatus(projectId: "x").method == "GET")
    }

    // ── Package.swift contract ────────────────────────────────────────────────

    @Test("Blitz target is importable")
    func blitzIsImportable() {
        // If @testable import Blitz above compiled, this trivially passes.
        #expect(Bool(true))
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

private func sidecarServiceSource() throws -> String {
    var url = URL(fileURLWithPath: #filePath)   // .../Tests/BlitzTests/CICDMigrationTests.swift
    url = url.deletingLastPathComponent()       // BlitzTests/
    url = url.deletingLastPathComponent()       // Tests/
    url = url.deletingLastPathComponent()       // package root
    url = url.appendingPathComponent("src/Services/NodeSidecarService.swift")

    guard FileManager.default.fileExists(atPath: url.path) else {
        throw SourceNotFound(path: url.path)
    }
    return try String(contentsOf: url, encoding: .utf8)
}

struct SourceNotFound: Error, CustomStringConvertible {
    let path: String
    var description: String { "Source file not found: \(path)" }
}

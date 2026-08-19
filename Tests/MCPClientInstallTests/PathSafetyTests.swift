import Foundation
import Testing

@testable import MCPClientInstall

@Suite("Path safety")
struct PathSafetyTests {
    @Test(
        "Configuration directories reject traversal and embedded separators",
        arguments: ["..", ".", "nested/path", "nested\\path", ""]
    )
    func configurationDirectoriesRejectUnsafeComponents(component: String) throws {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let preferred = MCPDesktopClient.ConfigurationLocation(
            directoryComponents: [component],
            fallbackDirectoryComponents: ["safe"],
            fileName: "config.json",
            format: .json
        )
        let fallback = MCPDesktopClient.ConfigurationLocation(
            directoryComponents: ["safe"],
            fallbackDirectoryComponents: [component],
            fileName: "config.json",
            format: .json
        )

        #expect(throws: MCPDesktopClient.ConfigurationLocationError.self) {
            try preferred.directory(relativeTo: home)
        }
        #expect(throws: MCPDesktopClient.ConfigurationLocationError.self) {
            try fallback.fallbackDirectory(relativeTo: home)
        }
    }

    @Test func configurationDirectoriesRejectNonFileHomeURLs() {
        let home = URL(string: "https://example.com/home")!
        let location = MCPDesktopClient.ConfigurationLocation(
            directoryComponents: ["safe"],
            fallbackDirectoryComponents: [],
            fileName: "config.json",
            format: .json
        )

        #expect(throws: MCPDesktopClient.ConfigurationLocationError.nonFileHomeURL(home)) {
            try location.directory(relativeTo: home)
        }
    }

    @Test func serverBackupSuffixCannotEscapeTheConfigurationDirectory() {
        let explicit = MCPServerSpec(
            name: "demo", command: "/demo", backupSuffix: "/tmp/stolen"
        )

        #expect(throws: Never.self) { try addingMCPServer(explicit, toJSON: [:]) }
        #expect(throws: MCPServerSpec.ValidationError.unsafeBackupSuffix("/tmp/stolen")) {
            try explicit.validate()
        }
    }

    @Test func defaultBackupSuffixIsSafeForServerNamesWithSeparators() throws {
        let server = MCPServerSpec(name: "team/server\\name", command: "/demo")

        #expect(isSafeFilenameSuffix(server.backupSuffix))
        #expect(try addingMCPServer(server, toJSON: [:]).root["mcpServers"] != nil)
        #expect(try addingMCPServer(server, toCodexTOML: "").text.contains("team/server"))
    }

    @Test func directWritesRejectUnsafeBackupSuffixesWithoutCreatingAFile() throws {
        let file = temporaryDirectory().appendingPathComponent("config.json")

        #expect(throws: MCPClientInstall.ConfigWriteError.self) {
            try MCPClientInstall.writeConfig(Data("{}".utf8), to: file, backupSuffix: "../backup")
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func restoreRejectsAnEscapingDisplacedSuffixBeforeMovingEitherFile() throws {
        let directory = temporaryDirectory()
        let file = directory.appendingPathComponent("config.json")
        let backup = directory.appendingPathComponent("config.json.backup")
        let server = MCPServerSpec(name: "demo", command: "/demo", backupSuffix: ".backup")
        try Data(#"{"live":true}"#.utf8).write(to: file)
        try Data(#"{"backup":true}"#.utf8).write(to: backup)

        #expect(throws: MCPClientInstall.InstallWorkflowError.self) {
            try MCPClientInstall.restoreBackup(
                for: server, format: .json, at: file, displacedSuffix: "../displaced"
            )
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == #"{"live":true}"#)
        #expect(try String(contentsOf: backup, encoding: .utf8) == #"{"backup":true}"#)
    }

    @Test func missingAndUninspectablePathsRemainDistinct() throws {
        let directory = temporaryDirectory()
        let missing = directory.appendingPathComponent("missing")
        #expect(MCPClientInstall.configPathKind(at: missing) == .absent)

        let locked = directory.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        }
        let inaccessible = locked.appendingPathComponent("config.json")
        guard case .unavailable = MCPClientInstall.configPathKind(at: inaccessible) else {
            Issue.record("A permissions failure was misclassified as an absent path")
            return
        }
    }

    @Test func danglingSymlinksAreUnsafeForJSONAndTOMLReads() throws {
        let directory = temporaryDirectory()
        let target = directory.appendingPathComponent("missing")
        let link = directory.appendingPathComponent("config")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: MCPClientInstall.ConfigurationReadError.self) {
            try MCPClientInstall.existingJSON(at: link)
        }
        #expect(throws: MCPClientInstall.ConfigurationReadError.self) {
            try MCPClientInstall.existingTOML(at: link)
        }
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@testable import MCPClientInstall

@Suite("Path safety")
struct PathSafetyTests {
    @Test func aParentDirectorySwapCannotRedirectTheTransaction() throws {
        let root = temporaryDirectory()
        let selected = root.appendingPathComponent("selected", isDirectory: true)
        let parked = root.appendingPathComponent("parked")
        let outside = temporaryDirectory()
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let file = selected.appendingPathComponent("config.json")
        let parkedFile = parked.appendingPathComponent("config.json")
        let outsideFile = outside.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: file)
        try Data(#"{"outside":true}"#.utf8).write(to: outsideFile)

        #expect(throws: MCPClientInstall.InstallWorkflowError.configurationChanged(url: file)) {
            try MCPClientInstall.writeConfig(
                Data(#"{"approved":true}"#.utf8),
                to: file,
                backupSuffix: ".backup",
                hooks: .init(
                    beforeReplacing: {},
                    afterCheckingTarget: {
                        guard rename(selected.path, parked.path) == 0,
                              symlink(outside.path, selected.path) == 0
                        else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    }
                )
            )
        }

        #expect(try Data(contentsOf: outsideFile) == Data(#"{"outside":true}"#.utf8))
        let parkedBackup = parked.appendingPathComponent("config.json.backup")
        let recoverableData = try Data(contentsOf:
            FileManager.default.fileExists(atPath: parkedFile.path) ? parkedFile : parkedBackup
        )
        #expect(recoverableData == Data("{}".utf8)
            || recoverableData == Data(#"{"approved":true}"#.utf8))
    }

    @Test(
        "Configuration directories reject traversal and embedded separators",
        arguments: ["..", ".", "nested/path", "nested\\path", "nul\0component", ""]
    )
    func configurationDirectoriesRejectUnsafeComponents(component: String) throws {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let preferred = try MCPDesktopClient.ConfigurationLocation(
            directoryComponents: [component],
            fallbackDirectoryComponents: ["safe"],
            fileName: "config.json",
            format: .json
        )
        let fallback = try MCPDesktopClient.ConfigurationLocation(
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

    @Test func configurationDirectoriesRejectNonFileHomeURLs() throws {
        let home = URL(string: "https://example.com/home")!
        let location = try MCPDesktopClient.ConfigurationLocation(
            directoryComponents: ["safe"],
            fallbackDirectoryComponents: [],
            fileName: "config.json",
            format: .json
        )

        #expect(throws: MCPDesktopClient.ConfigurationLocationError.nonFileHomeURL(home)) {
            try location.directory(relativeTo: home)
        }
    }

    @Test func configurationDirectoriesRejectSymlinkedComponents() throws {
        let home = temporaryDirectory()
        let outside = temporaryDirectory()
        let link = home.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let location = try MCPDesktopClient.ConfigurationLocation(
            directoryComponents: ["escape"],
            fallbackDirectoryComponents: [],
            fileName: "config.json",
            format: .json
        )

        #expect(throws: MCPDesktopClient.ConfigurationLocationError.self) {
            try location.directory(relativeTo: home)
        }
    }

    @Test func canonicalClientDirectorySymlinksAreRejected() throws {
        let home = temporaryDirectory()
        let outside = temporaryDirectory()
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".codex", isDirectory: true),
            withDestinationURL: outside
        )

        #expect(throws: MCPDesktopClient.ConfigurationLocationError.self) {
            try MCPDesktopClient.codex.configurationLocation.directory(relativeTo: home)
        }
    }

    @Test(
        "Configuration filenames reject traversal and embedded separators",
        arguments: ["..", ".", "../outside.json", "nested/config.json", "nested\\config.json", ""]
    )
    func configurationFilenamesRejectUnsafeComponents(fileName: String) {
        #expect(throws: MCPDesktopClient.ConfigurationLocationError.unsafeFileName(fileName)) {
            try MCPDesktopClient.ConfigurationLocation(
                directoryComponents: ["safe"],
                fallbackDirectoryComponents: [],
                fileName: fileName,
                format: .json
            )
        }
    }

    @Test func serverBackupSuffixCannotEscapeTheConfigurationDirectory() {
        let explicit = MCPServerSpec(
            name: "demo", command: "/demo", backupSuffix: "/tmp/stolen"
        )

        #expect(throws: MCPServerSpec.ValidationError.unsafeBackupSuffix("/tmp/stolen")) {
            try addingMCPServer(explicit, toJSON: [:])
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

    @Test func backupSuffixesRejectEmbeddedNUL() {
        let suffix = ".bad\0suffix"
        let server = MCPServerSpec(name: "demo", command: "/demo", backupSuffix: suffix)

        #expect(throws: MCPServerSpec.ValidationError.unsafeBackupSuffix(suffix)) {
            try addingMCPServer(server, toJSON: [:])
        }
        #expect(throws: MCPClientInstall.ConfigWriteError.unsafeBackupSuffix(suffix)) {
            try MCPClientInstall.writeConfig(Data(), to: temporaryDirectory(), backupSuffix: suffix)
        }
    }

    @Test func directWritesRejectUnsafeExistingTargets() throws {
        let directory = temporaryDirectory()
        let target = directory.appendingPathComponent("target")
        let link = directory.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: MCPClientInstall.ConfigWriteError.self) {
            try MCPClientInstall.writeConfig(
                Data(#"{"changed":true}"#.utf8), to: link, backupSuffix: ".backup"
            )
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "{}")
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

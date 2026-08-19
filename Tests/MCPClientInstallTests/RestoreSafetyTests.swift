import Foundation
import Testing

@testable import MCPClientInstall

@Suite("Restore and rollback safety")
struct RestoreSafetyTests {
    private let server = MCPServerSpec(name: "demo", command: "/demo", backupSuffix: ".backup")

    @Test func unsafeBackupPathsPreserveTheirClassification() throws {
        let directory = temporaryDirectory()
        let file = directory.appendingPathComponent("config.json")
        let backup = directory.appendingPathComponent("config.json.backup")
        let target = directory.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: backup, withDestinationURL: target)

        do {
            _ = try MCPClientInstall.restoreBackup(
                for: server, format: .json, at: file, displacedSuffix: ".displaced"
            )
            Issue.record("Expected unsafe backup path")
        } catch let error as MCPClientInstall.InstallWorkflowError {
            guard case let .unsafePath(url, .symbolicLink(destination)) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(url == backup)
            #expect(!destination.isEmpty)
        }
    }

    @Test func oversizedBackupsPreserveTheirConfiguredLimit() throws {
        let directory = temporaryDirectory()
        let file = directory.appendingPathComponent("config.json")
        let backup = directory.appendingPathComponent("config.json.backup")
        #expect(FileManager.default.createFile(atPath: backup.path, contents: nil))
        let writer = try FileHandle(forWritingTo: backup)
        try writer.truncate(atOffset: UInt64(MCPClientInstall.maxConfigurationFileBytes + 1))
        try writer.close()

        #expect(throws: MCPClientInstall.InstallWorkflowError.configurationTooLarge(
            url: backup,
            limit: MCPClientInstall.maxConfigurationFileBytes
        )) {
            try MCPClientInstall.restoreBackup(
                for: server, format: .json, at: file, displacedSuffix: ".displaced"
            )
        }
    }

    @Test func restorationDoesNotRequireAnExecutableCommand() throws {
        let directory = temporaryDirectory()
        let file = directory.appendingPathComponent("config.json")
        let backup = directory.appendingPathComponent("config.json.backup")
        try Data(#"{"mcpServers":{}}"#.utf8).write(to: backup)
        let recoverySpec = MCPServerSpec(name: "demo", command: " ", backupSuffix: ".backup")

        let result = try MCPClientInstall.restoreBackup(
            for: recoverySpec,
            format: .json,
            at: file,
            displacedSuffix: ".displaced"
        )

        #expect(result.displacedURL == nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func failedVerificationRemovesANewConfiguration() throws {
        let file = temporaryDirectory().appendingPathComponent("config.json")

        #expect(throws: MCPClientInstall.InstallWorkflowError.verificationFailed(
            url: file, backupURL: nil
        )) {
            try MCPClientInstall.installServer(
                server, format: .json, at: file, verificationOverride: { false }
            )
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func rollbackRemovalFailuresAreReportedDistinctly() throws {
        let file = temporaryDirectory().appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: file)

        do {
            _ = try MCPClientInstall.installServer(
                server,
                format: .json,
                at: file,
                verificationOverride: { false },
                removeItem: { _ in throw InjectedFailure() }
            )
            Issue.record("Expected rollback cleanup failure")
        } catch let error as MCPClientInstall.InstallWorkflowError {
            guard case let .verificationRollbackCleanupFailed(url, displacedURL, _) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(url == file)
            #expect(FileManager.default.fileExists(atPath: displacedURL.path))
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "{}")
    }

    @Test(
        "Malformed backups never replace the live configuration",
        arguments: [
            (MCPClientInstall.ConfigurationFormat.json, Data("{".utf8)),
            (.codexTOML, Data("model = \"unterminated".utf8))
        ]
    )
    func malformedBackupsRemainInactive(
        format: MCPClientInstall.ConfigurationFormat,
        backupData: Data
    ) throws {
        let directory = temporaryDirectory()
        let file = directory.appendingPathComponent("config")
        let backup = directory.appendingPathComponent("config.backup")
        let live = format == .json ? Data("{}".utf8) : Data("model = \"safe\"".utf8)
        try live.write(to: file)
        try backupData.write(to: backup)

        #expect(throws: MCPClientInstall.InstallWorkflowError.self) {
            try MCPClientInstall.restoreBackup(
                for: server, format: format, at: file, displacedSuffix: ".displaced"
            )
        }
        #expect(try Data(contentsOf: file) == live)
        #expect(try Data(contentsOf: backup) == backupData)
    }

    @Test func aFailedRestoreAndFailedRollbackReportsEveryRecoveryPath() throws {
        let directory = temporaryDirectory()
        let file = directory.appendingPathComponent("config.json")
        let backup = directory.appendingPathComponent("config.json.backup")
        try Data("{}".utf8).write(to: file)
        try Data(#"{"old":true}"#.utf8).write(to: backup)
        var moveCount = 0

        do {
            _ = try MCPClientInstall.restoreBackup(
                for: server,
                format: .json,
                at: file,
                displacedSuffix: ".displaced",
                moveItem: { source, destination in
                    moveCount += 1
                    if moveCount == 1 {
                        try FileManager.default.moveItem(at: source, to: destination)
                    } else {
                        throw InjectedFailure()
                    }
                }
            )
            Issue.record("Expected restoration rollback failure")
        } catch let error as MCPClientInstall.InstallWorkflowError {
            guard case let .restorationRollbackFailed(url, displaced, recovery, _) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(url == file)
            #expect(displaced.lastPathComponent == "config.json.displaced")
            #expect(recovery == backup)
        }
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct InjectedFailure: LocalizedError {
    var errorDescription: String? { "injected move failure" }
}

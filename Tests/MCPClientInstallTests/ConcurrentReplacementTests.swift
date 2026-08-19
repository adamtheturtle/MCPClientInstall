import Foundation
import Testing

@testable import MCPClientInstall

@Suite("Concurrent replacement safety")
struct ConcurrentReplacementTests {
    private let server = MCPServerSpec(name: "demo", command: "/demo", backupSuffix: ".backup")

    @Test func aReplacementLandingBeforeVerificationIsNeverRolledBack() throws {
        let directory = temporaryDirectory()
        let file = directory.appendingPathComponent("config.json")
        let backup = directory.appendingPathComponent("config.json.backup")
        let concurrent = Data(#"{"concurrent":true}"#.utf8)
        try Data("{}".utf8).write(to: file)

        // A replacement landing between the commit and the read-back is not the
        // file this install wrote, so rolling back would displace and delete
        // another writer's configuration.
        #expect(throws: MCPClientInstall.InstallWorkflowError.verificationTargetChanged(
            url: file, backupURL: backup
        )) {
            try MCPClientInstall.installServer(
                server,
                format: .json,
                at: file,
                afterWrite: { try? concurrent.write(to: file) }
            )
        }

        #expect(try Data(contentsOf: file) == concurrent)
        #expect(try Data(contentsOf: backup) == Data("{}".utf8))
    }

#if !os(Linux)
    @Test func aRefusedDarwinReplacementLeavesNoBackupBehind() throws {
        let directory = temporaryDirectory()
        let file = directory.appendingPathComponent("config.json")
        let backup = directory.appendingPathComponent("config.json.backup")
        let concurrent = Data(#"{"concurrent":true}"#.utf8)
        try Data("{}".utf8).write(to: file)

        #expect(throws: MCPClientInstall.InstallWorkflowError.configurationChanged(url: file)) {
            try MCPClientInstall.writeConfig(
                Data(#"{"approved":true}"#.utf8),
                to: file,
                backupSuffix: ".backup",
                hooks: .init(
                    beforeReplacing: {},
                    afterCheckingTarget: { try concurrent.write(to: file) }
                )
            )
        }

        // The reverse exchange put the concurrent file back. Leaving the refused
        // replacement at the backup path would let a later restore revive it.
        #expect(try Data(contentsOf: file) == concurrent)
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }
#endif

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

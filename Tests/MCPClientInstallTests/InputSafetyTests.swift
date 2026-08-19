import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@testable import MCPClientInstall

@Suite("Input and file safety")
struct InputSafetyTests {
    @Test func refusesInvalidObjectsBeforeFoundationSerialization() {
        #expect(throws: MCPClientInstall.JSONConfigError.invalidJSONObject) {
            try MCPClientInstall.prettyJSONData(from: ["nested": [Date()]])
        }
        #expect(throws: MCPClientInstall.JSONConfigError.invalidJSONObject) {
            try MCPClientInstall.prettyJSONData(from: ["number": Double.nan])
        }
    }

    @Test func cyclicFoundationContainersAreRejectedBeforeSerialization() {
        let cycle = NSMutableDictionary()
        cycle["self"] = cycle
        let arrayCycle = NSMutableArray()
        arrayCycle.add(arrayCycle)

        #expect(throws: MCPClientInstall.JSONConfigError.invalidJSONObject) {
            try MCPClientInstall.prettyJSONData(from: ["unrelated": cycle])
        }
        #expect(throws: MCPClientInstall.JSONConfigError.invalidJSONObject) {
            try MCPClientInstall.prettyJSONData(from: ["unrelated": arrayCycle])
        }
    }

    @Test func excessivelyDeepContainersAreRejectedBeforeSerialization() {
        var value: Any = "leaf"
        for _ in 0 ... 128 {
            value = [value]
        }

        #expect(throws: MCPClientInstall.JSONConfigError.invalidJSONObject) {
            try MCPClientInstall.prettyJSONData(from: ["deep": value])
        }
    }

    @Test func rejectsBlankServerIdentityAndCommandForEveryFormat() {
        #expect(throws: MCPServerSpec.ValidationError.blankName) {
            try addingMCPServer(MCPServerSpec(name: " \n", command: "/demo"), toJSON: [:])
        }
        #expect(throws: MCPServerSpec.ValidationError.blankCommand) {
            try addingMCPServer(MCPServerSpec(name: "demo", command: "\t"), toJSON: [:])
        }
        #expect(throws: MCPServerSpec.ValidationError.blankName) {
            try addingMCPServer(MCPServerSpec(name: " ", command: "/demo"), toCodexTOML: "")
        }
        #expect(throws: MCPServerSpec.ValidationError.blankCommand) {
            try addingMCPServer(MCPServerSpec(name: "demo", command: "\n"), toCodexTOML: "")
        }
    }

    @Test func rejectsNULInCommandsAndArguments() {
        let command = MCPServerSpec(name: "demo", command: "/demo\0hidden")
        let argument = MCPServerSpec(
            name: "demo", command: "/demo", arguments: ["safe", "bad\0hidden"]
        )

        #expect(throws: MCPServerSpec.ValidationError.commandContainsNUL) {
            try addingMCPServer(command, toJSON: [:])
        }
        #expect(throws: MCPServerSpec.ValidationError.argumentContainsNUL(index: 1)) {
            try addingMCPServer(argument, toCodexTOML: "")
        }
    }

    @Test func installReportsInvalidServersConsistentlyAcrossFormats() throws {
        let directory = temporaryDirectory()
        for format in [MCPClientInstall.ConfigurationFormat.json, .codexTOML] {
            let file = directory.appendingPathComponent(UUID().uuidString)
            do {
                _ = try MCPClientInstall.installServer(
                    MCPServerSpec(name: " ", command: "/demo"),
                    format: format,
                    at: file
                )
                Issue.record("Expected invalid server failure")
            } catch let error as MCPClientInstall.InstallWorkflowError {
                #expect(error == .invalidServer(.blankName))
            }
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func rejectedInstallsDoNotLeaveLocksBesideConfiguration() throws {
        let directory = temporaryDirectory()
        let file = directory.appendingPathComponent("config.json")
        let sidecar = directory.appendingPathComponent(".config.json.mcp-client-install.lock")
        try Data("{".utf8).write(to: file)

        #expect(throws: MCPClientInstall.InstallWorkflowError.self) {
            try MCPClientInstall.installServer(
                MCPServerSpec(name: "demo", command: "/demo"),
                format: .json,
                at: file
            )
        }
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
    }

    @Test func invalidServerTakesPriorityOverUnsafeConfigurationPath() throws {
        let directory = temporaryDirectory()
        let target = directory.appendingPathComponent("target")
        let link = directory.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: MCPClientInstall.InstallWorkflowError.invalidServer(.blankName)) {
            try MCPClientInstall.installServer(
                MCPServerSpec(name: " ", command: "/demo"),
                format: .json,
                at: link
            )
        }
    }

    @Test func restoreReportsInvalidBackupPoliciesAsWorkflowErrors() {
        let file = temporaryDirectory().appendingPathComponent("config.json")
        do {
            _ = try MCPClientInstall.restoreBackup(
                for: MCPServerSpec(
                    name: "demo", command: "", backupSuffix: "../unsafe"
                ),
                format: .json,
                at: file,
                displacedSuffix: ".displaced"
            )
            Issue.record("Expected invalid backup policy")
        } catch let error as MCPClientInstall.InstallWorkflowError {
            #expect(error == .invalidServer(.unsafeBackupSuffix("../unsafe")))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func executableSymlinksAreNotRunnable() throws {
        let directory = temporaryDirectory()
        let executable = directory.appendingPathComponent("tool")
        let link = directory.appendingPathComponent("tool-link")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)

        #expect(MCPClientInstall.isRunnableExecutable(executable.path))
        #expect(!MCPClientInstall.isRunnableExecutable(link.path))
    }

    @Test func boundedReadsRejectAFIFOBeforeOpeningIt() throws {
        let fifo = temporaryDirectory().appendingPathComponent("config.fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)

        #expect(throws: MCPClientInstall.ConfigurationReadError.unsafePath(.special)) {
            try MCPClientInstall.boundedConfigurationData(at: fifo)
        }
    }

    @Test func boundedReadsRemainBoundToTheOpenedFileAfterAPathSwap() throws {
        let directory = temporaryDirectory()
        let file = directory.appendingPathComponent("config.json")
        let outside = directory.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: file)
        try Data(#"{"outside":true}"#.utf8).write(to: outside)

        let data = try MCPClientInstall.boundedConfigurationData(at: file) {
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        }

        #expect(String(data: data, encoding: .utf8) == "{}")
    }

    @Test func refusesAnOversizedPreparedConfigurationWithoutWriting() throws {
        let file = temporaryDirectory().appendingPathComponent("config.json")
        let oversized = MCPServerSpec(
            name: "demo",
            command: String(repeating: "x", count: MCPClientInstall.maxConfigurationFileBytes)
        )

        #expect(throws: MCPClientInstall.InstallWorkflowError.self) {
            try MCPClientInstall.installServer(oversized, format: .json, at: file)
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func nonUTF8TOMLIsAnInvalidConfiguration() throws {
        let file = temporaryDirectory().appendingPathComponent("config.toml")
        try Data([0xFF]).write(to: file)

        do {
            _ = try MCPClientInstall.prepareServerUpdate(
                MCPServerSpec(name: "demo", command: "/demo"),
                format: .codexTOML,
                at: file
            )
            Issue.record("Expected invalid configuration")
        } catch let error as MCPClientInstall.InstallWorkflowError {
            guard case let .invalidConfiguration(url, _) = error else {
                Issue.record("Unexpected workflow error: \(error)")
                return
            }
            #expect(url == file)
        }
    }

    @Test func replacementTemporaryContainsSecretsOnlyAtMode0600() throws {
        let directory = temporaryDirectory()
        let file = directory.appendingPathComponent("config.json")
        let replacement = Data(#"{"token":"secret"}"#.utf8)
        try Data("{}".utf8).write(to: file)

        try MCPClientInstall.writeConfig(
            replacement,
            to: file,
            backupSuffix: ".backup",
            beforeReplacing: {
                let temporary = try #require(
                    FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                        .first { $0.lastPathComponent.hasSuffix(".tmp") }
                )
                let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
                let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
                #expect(permissions.intValue & 0o777 == 0o600)
                #expect(try Data(contentsOf: temporary) == replacement)
            }
        )
    }

    @Test func aSwappedReplacementTemporaryIsNeverCommitted() throws {
        let directory = temporaryDirectory()
        let file = directory.appendingPathComponent("config.json")
        let original = Data("{}".utf8)
        try original.write(to: file)

        #expect(throws: MCPClientInstall.InstallWorkflowError.self) {
            try MCPClientInstall.writeConfig(
                Data(#"{"approved":true}"#.utf8),
                to: file,
                backupSuffix: ".backup",
                beforeReplacing: {},
                afterWritingTemporary: { temporary in
                    try FileManager.default.removeItem(at: temporary)
                    try Data(#"{"malicious":true}"#.utf8).write(to: temporary)
                }
            )
        }

        #expect(try Data(contentsOf: file) == original)
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

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

    @Test func restoreReportsInvalidServersAsWorkflowErrors() {
        let file = temporaryDirectory().appendingPathComponent("config.json")
        do {
            _ = try MCPClientInstall.restoreBackup(
                for: MCPServerSpec(name: " ", command: "/demo"),
                format: .json,
                at: file,
                displacedSuffix: ".displaced"
            )
            Issue.record("Expected invalid server failure")
        } catch let error as MCPClientInstall.InstallWorkflowError {
            #expect(error == .invalidServer(.blankName))
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

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

import Foundation
@testable import MCPClientInstall
import Testing

@Suite("Configuration size limits")
struct ConfigurationSizeTests {
    @Test func `low level JSON read is bounded`() throws {
        let file = try oversizedFile(named: "config.json")

        #expect(throws: MCPClientInstall.ConfigurationReadError.self) {
            try MCPClientInstall.existingJSON(at: file)
        }
    }

    @Test func `workflow reports the bound and leaves input untouched`() throws {
        let file = try oversizedFile(named: "config.toml")
        let sizeBefore = try fileSize(at: file)
        let server = MCPServerSpec(name: "demo", command: "/demo")

        do {
            _ = try MCPClientInstall.installServer(
                server,
                format: .codexTOML,
                at: file,
            )
            Issue.record("Expected an oversized-file error")
        } catch let error as MCPClientInstall.InstallWorkflowError {
            guard case let .configurationTooLarge(_, limit) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(limit == MCPClientInstall.maxConfigurationFileBytes)
        }
        #expect(try fileSize(at: file) == sizeBefore)
    }

    @Test func `public writes reject oversized output before creating a file`() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let data = Data(count: MCPClientInstall.maxConfigurationFileBytes + 1)

        #expect(throws: MCPClientInstall.ConfigWriteError.configurationTooLarge(
            limit: MCPClientInstall.maxConfigurationFileBytes
        )) {
            try MCPClientInstall.writeConfig(data, to: file, backupSuffix: ".backup")
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    private func oversizedFile(named name: String) throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let writer = try FileHandle(forWritingTo: file)
        try writer.truncate(atOffset: UInt64(MCPClientInstall.maxConfigurationFileBytes + 1))
        try writer.close()
        return file
    }

    private func fileSize(at url: URL) throws -> UInt64? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64
    }
}

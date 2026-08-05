import Foundation
import MCPClientInstall
import Testing

@Suite("Public API")
struct PublicAPITests {
    @Test func `prepares an update for host confirmation`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("mcp.json")
        let server = MCPServerSpec(name: "demo", command: "/usr/bin/demo")
        let preview = try MCPClientInstall.prepareServerUpdate(server, format: .json, at: file)

        #expect(preview.format == .json)
        #expect(!preview.alreadyPresent)
        #expect(!preview.data.isEmpty)
    }
}

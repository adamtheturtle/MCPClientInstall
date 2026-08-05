import Foundation
import Testing

@testable import MCPClientInstall

@Suite("JSON safety")
struct JSONSafetyTests {
    @Test(
        "Duplicate object keys are rejected at every nesting level",
        arguments: [
            #"{"mcpServers":{},"mcpServers":{}}"#,
            #"{"mcpServers":{"demo":{"command":"a","command":"b"}}}"#,
            #"{"outer":[{"args":[],"args":["--other"]}]}"#
        ]
    )
    func duplicateKeysAreRejected(text: String) throws {
        let file = temporaryDirectory().appendingPathComponent("config.json")
        try Data(text.utf8).write(to: file)

        #expect(throws: MCPClientInstall.JSONConfigError.self) {
            try MCPClientInstall.existingJSON(at: file)
        }
    }

    @Test func escapedAndLiteralEquivalentKeysAreDuplicates() throws {
        let file = temporaryDirectory().appendingPathComponent("config.json")
        try Data(#"{"command":"a","comm\u0061nd":"b"}"#.utf8).write(to: file)

        #expect(throws: MCPClientInstall.JSONConfigError.duplicateKey("command")) {
            try MCPClientInstall.existingJSON(at: file)
        }
    }

    @Test func byteOrderMarkDoesNotBypassDuplicateKeyDetection() throws {
        let file = temporaryDirectory().appendingPathComponent("config.json")
        let byteOrderMark = Data([0xEF, 0xBB, 0xBF])
        try (byteOrderMark + Data(#"{"command":"a","command":"b"}"#.utf8)).write(to: file)

        #expect(throws: MCPClientInstall.JSONConfigError.duplicateKey("command")) {
            try MCPClientInstall.existingJSON(at: file)
        }
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

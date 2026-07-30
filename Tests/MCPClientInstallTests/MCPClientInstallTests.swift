import Foundation
import Testing

@testable import MCPClientInstall

@Suite("JSON configuration")
struct JSONConfigTests {
    @Test func preservesUnrelatedKeysAndReportsReplacement() throws {
        let root: [String: Any] = [
            "theme": "dark",
            "mcpServers": ["other": ["command": "/other"]]
        ]
        let server = MCPServerSpec(name: "demo", command: "/usr/bin/demo", productName: "Demo")

        let first = try MCPClientInstall.jsonConfigByAddingServer(to: root, server: server)
        #expect(!first.alreadyPresent)
        #expect(first.root["theme"] as? String == "dark")

        let second = try MCPClientInstall.jsonConfigByAddingServer(to: first.root, server: server)
        #expect(second.alreadyPresent)
    }

    @Test func refusesAnIncompatibleServersValue() {
        #expect(throws: MCPClientInstall.JSONConfigError.self) {
            try MCPClientInstall.jsonConfigByAddingServer(
                to: ["mcpServers": "do not overwrite me"],
                server: MCPServerSpec(name: "demo", command: "demo", productName: "Demo")
            )
        }
    }

    @Test func refusesAnIncompatibleExistingServer() {
        #expect(throws: MCPClientInstall.JSONConfigError.self) {
            try MCPClientInstall.jsonConfigByAddingServer(
                to: ["mcpServers": ["demo": "do not overwrite me"]],
                server: MCPServerSpec(name: "demo", command: "demo", productName: "Demo")
            )
        }
    }

    @Test func verifiesTheExpectedServerShape() throws {
        let server = MCPServerSpec(name: "demo", command: "/demo", productName: "Demo")
        let merged = try addingMCPServer(server, toJSON: [:])
        #expect(mcpServerIsConfigured(server, inJSON: merged.root))
        #expect(!mcpServerIsConfigured(
            MCPServerSpec(name: "demo", command: "/other", productName: "Demo"),
            inJSON: merged.root
        ))
    }

    @Test func absentAndWhitespaceOnlyFilesAreEmpty() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let missing = directory.appendingPathComponent("missing.json")
        #expect(try MCPClientInstall.existingJSON(at: missing).isEmpty)

        let blank = directory.appendingPathComponent("blank.json")
        try Data(" \n\t".utf8).write(to: blank)
        #expect(try MCPClientInstall.existingJSON(at: blank).isEmpty)
    }
}

@Suite("Codex TOML configuration")
struct TOMLConfigTests {
    private let server = MCPServerSpec(
        name: "demo.server",
        command: #"/tmp/a"b\c"#,
        arguments: ["--serve", "two words"],
        productName: "Demo"
    )

    @Test func escapesBasicStringsAndQuotesDottedServerNames() {
        #expect(MCPClientInstall.tomlBasicString(#"a"b\c"#) == #""a\"b\\c""#)
        let block = MCPClientInstall.codexServerBlock(for: server)
        #expect(block.contains(#"[mcp_servers."demo.server"]"#))
        #expect(block.contains(#"args = ["--serve", "two words"]"#))
    }

    @Test func appendsWithoutChangingExistingText() throws {
        let original = "[features]\nenabled = true\n"
        let merged = try MCPClientInstall.codexConfigByAddingServer(to: original, server: server)
        #expect(!merged.alreadyPresent)
        #expect(merged.text.hasPrefix(original))
        #expect(merged.text.contains(#"[mcp_servers."demo.server"]"#))
    }

    @Test func replacesOnlyOwnedKeysAndPreservesCustomSettings() throws {
        let original = """
        [mcp_servers."demo.server"]
        command = "/old"
        env = { TOKEN = "keep" }
        args = ["old"]

        [features]
        enabled = true
        """
        let merged = try MCPClientInstall.codexConfigByAddingServer(to: original, server: server)
        #expect(merged.alreadyPresent)
        #expect(merged.text.contains(#"env = { TOKEN = "keep" }"#))
        #expect(merged.text.contains("[features]"))
        #expect(!merged.text.contains(#"command = "/old""#))
    }

    @Test func ignoresHeaderLikeTextInsideMultilineValues() throws {
        let original = #"""
        notes = """
        [mcp_servers."demo.server"]
        """
        """#
        let scan = MCPClientInstall.scanCodexConfig(original, serverName: server.name)
        #expect(scan.declaration == .notDeclared)
    }

    @Test func refusesConflictingDeclarationForms() {
        let dotted = #"mcp_servers."demo.server".command = "/old""#
        #expect(throws: MCPClientInstall.TOMLConfigError.self) {
            try MCPClientInstall.codexConfigByAddingServer(to: dotted, server: server)
        }
    }

    @Test func retainsCRLFLineEndings() throws {
        let original = "[features]\r\nenabled = true\r\n"
        let merged = try MCPClientInstall.codexConfigByAddingServer(to: original, server: server)
        #expect(MCPClientInstall.dominantLineEnding(of: merged.text) == "\r\n")
    }

    @Test func verifiesTheExpectedCodexServerShape() throws {
        let merged = try addingMCPServer(server, toCodexTOML: "")
        #expect(mcpServerIsConfigured(server, inCodexTOML: merged.text))
        #expect(!mcpServerIsConfigured(
            MCPServerSpec(name: server.name, command: "/other", productName: "Demo"),
            inCodexTOML: merged.text
        ))
    }
}

@Suite("Configuration paths")
struct ConfigPathTests {
    @Test func classifiesAbsentAndRegularFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("config.json")
        #expect(MCPClientInstall.configPathKind(at: file) == .absent)
        try Data("{}".utf8).write(to: file)
        #expect(MCPClientInstall.configPathKind(at: file) == .regularFile)
    }
}

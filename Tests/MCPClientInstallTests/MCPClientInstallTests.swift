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
        let server = MCPServerSpec(name: "demo", command: "/usr/bin/demo")

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
                server: MCPServerSpec(name: "demo", command: "demo")
            )
        }
    }

    @Test func refusesAnIncompatibleExistingServer() {
        #expect(throws: MCPClientInstall.JSONConfigError.self) {
            try MCPClientInstall.jsonConfigByAddingServer(
                to: ["mcpServers": ["demo": "do not overwrite me"]],
                server: MCPServerSpec(name: "demo", command: "demo")
            )
        }
    }

    @Test func preservesCustomSettingsWhenUpdatingServer() throws {
        let root: [String: Any] = [
            "mcpServers": [
                "demo": [
                    "command": "/old",
                    "args": ["old"],
                    "env": ["TOKEN": "keep"],
                    "disabled": true,
                    "timeout": 30
                ]
            ]
        ]
        let server = MCPServerSpec(
            name: "demo",
            command: "/new",
            arguments: ["new"]
        )

        let merged = try MCPClientInstall.jsonConfigByAddingServer(to: root, server: server)
        let servers = try #require(merged.root["mcpServers"] as? [String: Any])
        let entry = try #require(servers["demo"] as? [String: Any])

        #expect(entry["command"] as? String == "/new")
        #expect(entry["args"] as? [String] == ["new"])
        #expect(entry["env"] as? [String: String] == ["TOKEN": "keep"])
        #expect(entry["disabled"] as? Bool == true)
        #expect(entry["timeout"] as? Int == 30)
    }

    @Test func verifiesTheExpectedServerShape() throws {
        let server = MCPServerSpec(name: "demo", command: "/demo")
        let merged = try addingMCPServer(server, toJSON: [:])
        #expect(mcpServerIsConfigured(server, inJSON: merged.root))
        #expect(!mcpServerIsConfigured(
            MCPServerSpec(name: "demo", command: "/other"),
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

    @Test func refusesNonUTF8Files() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data([0xff]).write(to: file)

        #expect(throws: CocoaError.self) {
            try MCPClientInstall.existingJSON(at: file)
        }
    }
}

@Suite("Codex TOML configuration")
struct TOMLConfigTests {
    private let server = MCPServerSpec(
        name: "demo.server",
        command: #"/tmp/a"b\c"#,
        arguments: ["--serve", "two words"]
    )

    @Test func escapesBasicStringsAndQuotesDottedServerNames() {
        #expect(MCPClientInstall.tomlBasicString(#"a"b\c"#) == #""a\"b\\c""#)
        #expect(MCPClientInstall.tomlBasicString("a\u{7F}\u{80}\u{9F}b") == #""a\u007F\u0080\u009Fb""#)
        #expect(MCPClientInstall.tomlBasicString("a\u{A0}b") == "\"a\u{A0}b\"")
        let block = MCPClientInstall.codexServerBlock(for: server)
        #expect(block.contains(#"[mcp_servers."demo.server"]"#))
        #expect(block.contains(#"args = ["--serve", "two words"]"#))
    }

    @Test func quotesUnicodeServerNames() {
        let unicodeServer = MCPServerSpec(
            name: "café",
            command: "/demo"
        )

        let block = MCPClientInstall.codexServerBlock(for: unicodeServer)
        #expect(block.contains(#"[mcp_servers."café"]"#))
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

    @Test func replacesCompleteMultilineOwnedValues() throws {
        let original = #"""
        [mcp_servers."demo.server"]
        command = """
        /old
        """
        args = [
          "old",
        ]
        env = { TOKEN = "keep" }
        """#

        let merged = try MCPClientInstall.codexConfigByAddingServer(to: original, server: server)

        #expect(merged.alreadyPresent)
        #expect(merged.text.contains(#"command = "/tmp/a\"b\\c""#))
        #expect(merged.text.contains(#"args = ["--serve", "two words"]"#))
        #expect(merged.text.contains(#"env = { TOKEN = "keep" }"#))
        #expect(!merged.text.contains("/old"))
        #expect(!merged.text.contains(#""old""#))
        #expect(!merged.text.contains(#"""""#))
    }

    @Test func refusesAnUnclosedOwnedValue() {
        let original = #"""
        [mcp_servers."demo.server"]
        command = "/old"
        args = [
          "old",
        """#

        #expect(throws: MCPClientInstall.TOMLConfigError.self) {
            try MCPClientInstall.codexConfigByAddingServer(to: original, server: server)
        }
    }

    @Test(
        "Refuses malformed TOML before merging",
        arguments: [
            "model = \"gpt",
            "model = 'gpt",
            "model =",
            #"model = "bad\q""#,
            "model = 1]",
            #"models = ["a" "b"]"#,
            "model = \"a\"\nmodel = \"b\"",
            "[profile]\n[profile]",
            "model = \"a\" nonsense",
            "model = definitely-not-a-value",
            "profile = { model = \"a\""
        ]
    )
    func refusesMalformedTOML(original: String) {
        #expect(throws: MCPClientInstall.TOMLConfigError.self) {
            try MCPClientInstall.codexConfigByAddingServer(to: original, server: server)
        }
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

    @Test func recognizesUnicodeEscapesInQuotedServerKeys() throws {
        let escaped = #"""
        [mcp_servers."demo\u002Eserver"]
        command = "/old"
        args = ["old"]
        """#

        let merged = try MCPClientInstall.codexConfigByAddingServer(to: escaped, server: server)

        #expect(merged.alreadyPresent)
        #expect(!merged.text.contains(#"\u002E"#))
        #expect(!merged.text.contains(#"command = "/old""#))
        #expect(merged.text.contains(#"[mcp_servers."demo.server"]"#))

        let longEscape = #"""
        [mcp_servers."demo\U0000002Eserver"]
        command = "/old"
        args = ["old"]
        """#
        #expect(
            MCPClientInstall.scanCodexConfig(longEscape, serverName: server.name).declaration
                == .table
        )
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
            MCPServerSpec(name: server.name, command: "/other"),
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

@Suite("Transactional installation")
struct InstallWorkflowTests {
    private let server = MCPServerSpec(name: "demo", command: "/demo", backupSuffix: ".backup")

    @Test func installsAbsentJSONAndVerifiesIt() throws {
        let file = temporaryDirectory().appendingPathComponent("config.json")

        let result = try MCPClientInstall.installServer(
            server,
            format: .json,
            at: file
        )

        #expect(result.backupURL == nil)
        #expect(mcpServerIsConfigured(server, inJSON: try readMCPJSONConfiguration(at: file)))
    }

    @Test func installsAbsentCodexTOMLAndVerifiesIt() throws {
        let file = temporaryDirectory().appendingPathComponent("config.toml")

        _ = try MCPClientInstall.installServer(
            server,
            format: .codexTOML,
            at: file
        )

        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(mcpServerIsConfigured(server, inCodexTOML: text))
    }

    @Test(
        "Rejects malformed and incompatible JSON before writing",
        arguments: [Data("{".utf8), Data(#"{"mcpServers":{"demo":"keep"}}"#.utf8)]
    )
    func refusesUnsafeJSON(data: Data) throws {
        let file = temporaryDirectory().appendingPathComponent("config.json")
        try data.write(to: file)

        #expect(throws: MCPClientInstall.InstallWorkflowError.self) {
            try MCPClientInstall.installServer(
                server,
                format: .json,
                at: file
            )
        }
        #expect(try Data(contentsOf: file) == data)
    }

    @Test func backsUpAndRestoresARegularJSONFile() throws {
        let file = temporaryDirectory().appendingPathComponent("config.json")
        try Data(#"{"theme":"dark"}"#.utf8).write(to: file)

        let installed = try MCPClientInstall.installServer(
            server,
            format: .json,
            at: file
        )
        let backup = try #require(installed.backupURL)
        #expect(FileManager.default.fileExists(atPath: backup.path))

        let restored = try MCPClientInstall.restoreBackup(
            for: server,
            at: file,
            displacedSuffix: ".replaced"
        )
        let displaced = try #require(restored.displacedURL)
        #expect(try String(contentsOf: file, encoding: .utf8) == #"{"theme":"dark"}"#)
        #expect(FileManager.default.fileExists(atPath: displaced.path))
    }

    @Test func verificationFailureReportsTheRecoverableBackup() throws {
        let file = temporaryDirectory().appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: file)

        do {
            _ = try MCPClientInstall.installServer(
                server,
                format: .json,
                at: file,
                verificationOverride: { false }
            )
            Issue.record("Expected verification to fail")
        } catch let error as MCPClientInstall.InstallWorkflowError {
            guard case let .verificationFailed(_, backupURL) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(backupURL?.lastPathComponent == "config.json.backup")
            #expect(FileManager.default.fileExists(atPath: backupURL?.path ?? ""))
        }
    }

    @Test func repeatedUpdatesRotateTheRecoverableBackup() throws {
        let file = temporaryDirectory().appendingPathComponent("config.json")
        try Data(#"{"version":1}"#.utf8).write(to: file)
        _ = try MCPClientInstall.installServer(server, format: .json, at: file)

        try Data(#"{"version":2}"#.utf8).write(to: file)
        _ = try MCPClientInstall.installServer(server, format: .json, at: file)

        let backup = file.deletingLastPathComponent()
            .appendingPathComponent(file.lastPathComponent + server.backupSuffix)
        #expect(try String(contentsOf: backup, encoding: .utf8) == #"{"version":2}"#)
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

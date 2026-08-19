import Testing

@testable import MCPClientInstall

@Suite("TOML semantic verification")
struct TOMLSemanticsTests {
    @Test func verificationComparesDecodedValues() {
        let semantic = """
        [mcp_servers.demo]
        command="/demo" # equivalent spacing and comment
        args=[
          "--mcp",
        ]
        """
        let expected = MCPServerSpec(name: "demo", command: "/demo")
        #expect(mcpServerIsConfigured(expected, inCodexTOML: semantic))
    }

    @Test func verificationIgnoresMatchingTextInsideMultilineStrings() {
        let misleading = #"""
        [mcp_servers.demo]
        notes = """
        command = "/demo"
        args = ["--mcp"]
        """
        """#
        let expected = MCPServerSpec(name: "demo", command: "/demo")
        #expect(!mcpServerIsConfigured(expected, inCodexTOML: misleading))
    }

    @Test func quotedServerKeyWhitespaceRemainsSignificant() throws {
        let original = #"""
        [mcp_servers." demo "]
        command = "/spaced"
        args = ["--mcp"]
        """#
        #expect(MCPClientInstall.scanCodexConfig(original, serverName: " demo ").declaration == .table)
        #expect(MCPClientInstall.scanCodexConfig(original, serverName: "demo").declaration == .notDeclared)

        let merged = try MCPClientInstall.codexConfigByAddingServer(
            to: original,
            server: MCPServerSpec(name: "demo", command: "/plain")
        )
        #expect(!merged.alreadyPresent)
        #expect(merged.text.contains(#"[mcp_servers." demo "]"#))
        #expect(merged.text.contains("[mcp_servers.demo]"))
    }

    @Test func headerCommentBracketDoesNotHideExistingServer() throws {
        let original = """
        [mcp_servers.demo] # misleading ]
        command = "/old"
        args = ["old"]
        """
        let server = MCPServerSpec(name: "demo", command: "/new", arguments: ["new"])

        let merged = try MCPClientInstall.codexConfigByAddingServer(to: original, server: server)

        #expect(merged.alreadyPresent)
        #expect(merged.text.components(separatedBy: "[mcp_servers.demo]").count == 2)
        #expect(MCPClientInstall.codexServerIsConfigured(server, in: merged.text))
        #expect(throws: Never.self) {
            try MCPClientInstall.validateCodexTOML(merged.text)
        }
    }

    @Test(
        "Incompatible mcp_servers ancestors are rejected",
        arguments: [
            #"mcp_servers = "not a table""#,
            #"mcp_servers = { demo = { command = "/old", args = ["old"] } }"#
        ]
    )
    func incompatibleMCPServersAncestorsAreRejected(original: String) {
        let server = MCPServerSpec(name: "demo", command: "/new")

        #expect(throws: MCPClientInstall.TOMLConfigError.self) {
            try MCPClientInstall.codexConfigByAddingServer(to: original, server: server)
        }
    }
}

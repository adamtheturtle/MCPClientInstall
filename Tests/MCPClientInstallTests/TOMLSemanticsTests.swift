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
}

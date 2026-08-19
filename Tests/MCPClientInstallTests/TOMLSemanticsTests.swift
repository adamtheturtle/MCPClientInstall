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

    @Test func preservesBlankLinesInsideCustomMultilineStrings() throws {
        let original = #"""
        [mcp_servers.demo]
        command = "/old"
        args = ["old"]
        note = """
        one

        two
        """
        """#
        let server = MCPServerSpec(name: "demo", command: "/new")

        let merged = try MCPClientInstall.codexConfigByAddingServer(to: original, server: server)

        #expect(merged.alreadyPresent)
        #expect(merged.text.contains("one\n\ntwo"))
        #expect(throws: Never.self) {
            try MCPClientInstall.validateCodexTOML(merged.text)
        }
    }

    @Test func byteOrderMarkDoesNotHideExistingServerTable() throws {
        let original = "\u{FEFF}[mcp_servers.demo]\ncommand = \"/old\"\nargs = [\"old\"]\n"
        let server = MCPServerSpec(name: "demo", command: "/new")

        let merged = try MCPClientInstall.codexConfigByAddingServer(to: original, server: server)

        #expect(merged.alreadyPresent)
        #expect(merged.text.hasPrefix("\u{FEFF}[mcp_servers.demo]"))
        #expect(merged.text.components(separatedBy: "[mcp_servers.demo]").count == 2)
        #expect(MCPClientInstall.codexServerIsConfigured(server, in: merged.text))
    }

    @Test func mixedLineEndingsRemainUnchangedOutsideTheServerTable() throws {
        let prefix = "[unrelated]\r\nvalue = 1\n"
        let serverTable = "[mcp_servers.demo]\r\ncommand = \"/old\"\nargs = [\"old\"]\r\n"
        let suffix = "[tail]\nvalue = 2\r\n"
        let original = prefix + serverTable + suffix
        let server = MCPServerSpec(name: "demo", command: "/new")

        let merged = try MCPClientInstall.codexConfigByAddingServer(to: original, server: server)

        #expect(merged.alreadyPresent)
        #expect(merged.text.hasPrefix(prefix))
        #expect(merged.text.hasSuffix(suffix))
        #expect(MCPClientInstall.codexServerIsConfigured(server, in: merged.text))
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

    @Test(
        "Owned dotted-key descendants are incompatible",
        arguments: ["command.value", "args.value"]
    )
    func ownedDottedKeyDescendantsAreIncompatible(key: String) {
        let original = """
        [mcp_servers.demo]
        \(key) = "old"
        """
        let server = MCPServerSpec(name: "demo", command: "/new")

        #expect(throws: MCPClientInstall.TOMLConfigError.self) {
            try MCPClientInstall.codexConfigByAddingServer(to: original, server: server)
        }
    }

    @Test func nestedCustomTablesArePreserved() throws {
        let original = """
        [mcp_servers.demo]
        command = "/old"
        args = ["old"]

        [mcp_servers.demo.env]
        TOKEN = "keep"

        [[mcp_servers.demo.routes]]
        path = "/one"
        """
        let server = MCPServerSpec(name: "demo", command: "/new", arguments: ["new"])

        let merged = try MCPClientInstall.codexConfigByAddingServer(to: original, server: server)

        #expect(merged.alreadyPresent)
        #expect(merged.text.contains("[mcp_servers.demo.env]"))
        #expect(merged.text.contains("TOKEN = \"keep\""))
        #expect(merged.text.contains("[[mcp_servers.demo.routes]]"))
        #expect(merged.text.contains("path = \"/one\""))
        #expect(MCPClientInstall.codexServerIsConfigured(server, in: merged.text))
    }
}

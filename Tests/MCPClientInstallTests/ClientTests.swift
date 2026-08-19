import Foundation
@testable import MCPClientInstall
import Testing

@Suite("Desktop clients")
struct ClientTests {
    @Test func `identity is stable for hash based selection`() {
        let selected: Set<MCPDesktopClient> = [.claudeDesktop, .codex, .claudeDesktop]

        #expect(selected == [.claudeDesktop, .codex])
        #expect(MCPDesktopClient.cursor.id == MCPDesktopClient.cursor.rawValue)
    }

    @Test func `configuration locations are relative to a caller supplied home`() throws {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        let desktop = MCPDesktopClient.claudeDesktop.configurationLocation
        #expect(try desktop.directory(relativeTo: home).path == "/Users/example/Library/Application Support/Claude")
        #expect(try desktop.fallbackDirectory(relativeTo: home).path == "/Users/example/Library/Application Support")
        #expect(desktop.fileName == "claude_desktop_config.json")
        #expect(try desktop.file(relativeTo: home).path
            == "/Users/example/Library/Application Support/Claude/claude_desktop_config.json")
        #expect(desktop.format == .json)

        let codex = MCPDesktopClient.codex.configurationLocation
        #expect(try codex.directory(relativeTo: home).path == "/Users/example/.codex")
        #expect(try codex.fallbackDirectory(relativeTo: home) == home)
        #expect(codex.fileName == "config.toml")
        #expect(codex.format == .codexTOML)
    }

    @Test func `display paths derive from canonical locations`() {
        #expect(MCPDesktopClient.claudeDesktop.configPath
            == "~/Library/Application Support/Claude/claude_desktop_config.json")
        #expect(MCPDesktopClient.claudeCode.configPath == "~/.claude.json")
        #expect(MCPDesktopClient.codex.configPath == "~/.codex/config.toml")
        #expect(MCPDesktopClient.cursor.configPath == "~/.cursor/mcp.json")
    }

    @Test func `config snippets reject invalid server specs`() {
        let invalid = MCPServerSpec(name: " ", command: " ")

        for client in MCPDesktopClient.allCases {
            #expect(throws: MCPServerSpec.ValidationError.blankName) {
                try client.configSnippet(for: invalid)
            }
        }
    }

    @Test func `config snippets contain valid servers`() throws {
        let server = MCPServerSpec(name: "demo", command: "/demo")

        #expect(try MCPDesktopClient.cursor.configSnippet(for: server).contains("mcpServers"))
        #expect(try MCPDesktopClient.codex.configSnippet(for: server).contains("mcp_servers.demo"))
    }

    @Test func `verification hints never interpolate server names into shell commands`() throws {
        let unsafeShellText = "name; $(touch /tmp/unwanted) `code`\nnext"
        let hint = try #require(MCPDesktopClient.claudeCode.verifyHint(serverName: unsafeShellText))

        #expect(hint == "Confirm it connected with `claude mcp list`.")
        #expect(!hint.contains(unsafeShellText))
    }
}

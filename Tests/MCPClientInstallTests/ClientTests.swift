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

    @Test func `configuration locations are relative to a caller supplied home`() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        let desktop = MCPDesktopClient.claudeDesktop.configurationLocation
        #expect(desktop.directory(relativeTo: home).path == "/Users/example/Library/Application Support/Claude")
        #expect(desktop.fallbackDirectory(relativeTo: home).path == "/Users/example/Library/Application Support")
        #expect(desktop.fileName == "claude_desktop_config.json")
        #expect(desktop.format == .json)

        let codex = MCPDesktopClient.codex.configurationLocation
        #expect(codex.directory(relativeTo: home).path == "/Users/example/.codex")
        #expect(codex.fallbackDirectory(relativeTo: home) == home)
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
}

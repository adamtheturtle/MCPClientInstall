@testable import MCPClientInstall
import Testing

@Suite("Desktop clients")
struct ClientTests {
    @Test func `identity is stable for hash based selection`() {
        let selected: Set<MCPDesktopClient> = [.claudeDesktop, .codex, .claudeDesktop]

        #expect(selected == [.claudeDesktop, .codex])
        #expect(MCPDesktopClient.cursor.id == MCPDesktopClient.cursor.rawValue)
    }
}

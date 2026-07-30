import Foundation

/// Adds or updates an MCP server in a JSON configuration root.
///
/// This top-level spelling is convenient for applications that already have a
/// local type named `MCPClientInstall`.
public func addingMCPServer(
    _ server: MCPServerSpec,
    toJSON root: [String: Any]
) throws -> MCPClientInstall.JSONMergeResult {
    try MCPClientInstall.jsonConfigByAddingServer(to: root, server: server)
}

/// Adds or updates an MCP server in a Codex TOML configuration.
///
/// Existing unrelated tables and settings are retained.
public func addingMCPServer(
    _ server: MCPServerSpec,
    toCodexTOML text: String
) throws -> (text: String, alreadyPresent: Bool) {
    try MCPClientInstall.codexConfigByAddingServer(to: text, server: server)
}

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

/// Reads a JSON configuration, treating an absent or whitespace-only file as empty.
public func readMCPJSONConfiguration(at url: URL) throws -> [String: Any] {
    try MCPClientInstall.existingJSON(at: url)
}

/// Serializes a JSON configuration with stable, human-readable formatting.
public func serializedMCPJSONConfiguration(_ root: [String: Any]) throws -> Data {
    try MCPClientInstall.prettyJSONData(from: root)
}

/// Replaces a configuration safely and leaves the previous contents beside it.
public func writeMCPConfiguration(
    _ data: Data,
    to url: URL,
    backupSuffix: String
) throws {
    try MCPClientInstall.writeConfig(data, to: url, backupSuffix: backupSuffix)
}

/// Whether a path names a runnable regular executable file.
public func isRunnableMCPExecutable(atPath path: String) -> Bool {
    MCPClientInstall.isRunnableExecutable(path)
}

/// Classifies a configuration path without following symbolic links.
public func classifyMCPConfigurationPath(
    at url: URL
) -> MCPClientInstall.ConfigPathKind {
    MCPClientInstall.configPathKind(at: url)
}

/// Explains why a configuration path cannot be safely replaced.
public func mcpConfigurationPathRefusalReason(
    for kind: MCPClientInstall.ConfigPathKind,
    fileName: String
) -> String? {
    MCPClientInstall.refusalReason(for: kind, fileName: fileName)
}

/// Whether a JSON root contains exactly the supplied command and arguments.
public func mcpServerIsConfigured(
    _ server: MCPServerSpec,
    inJSON root: [String: Any]
) -> Bool {
    guard let servers = root["mcpServers"] as? [String: Any],
          let entry = servers[server.name] as? [String: Any],
          entry["command"] as? String == server.command,
          entry["args"] as? [String] == server.arguments
    else { return false }

    return true
}

/// Whether a Codex configuration contains exactly the supplied server table.
public func mcpServerIsConfigured(
    _ server: MCPServerSpec,
    inCodexTOML text: String
) -> Bool {
    let scan = MCPClientInstall.scanCodexConfig(text, serverName: server.name)
    guard scan.declaration == .table, let range = scan.tableLineRange else { return false }

    let table = scan.lines[range].map { $0.trimmingCharacters(in: .whitespaces) }
    let arguments = server.arguments
        .map(MCPClientInstall.tomlBasicString)
        .joined(separator: ", ")
    return table.contains("command = \(MCPClientInstall.tomlBasicString(server.command))")
        && table.contains("args = [\(arguments)]")
}

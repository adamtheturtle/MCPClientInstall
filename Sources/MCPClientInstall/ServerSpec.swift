//
//  ServerSpec.swift
//  MCPClientInstall
//
//  The identity of the MCP server entry being installed into a desktop client's
//  config. Parameterises every path that used to hard-code a product name, so
//  any host app can reuse the merge/write machinery unchanged.
//

/// The server entry written into each client's config file.
///
/// Every field is part of the on-disk payload or of user-facing messaging, so a
/// host app supplies all of them and the package never invents a product identity.
public struct MCPServerSpec: Sendable, Equatable {
    /// Config key under `mcpServers` / `[mcp_servers.<name>]`, e.g. `"myapp"`.
    public var name: String
    /// Absolute path (or command) the client should launch.
    public var command: String
    /// Arguments passed to `command`, e.g. `["--mcp"]`.
    public var arguments: [String]
    /// Suffix appended to the previous config when rewriting an existing file,
    /// e.g. `".myapp-mcp-backup"`. Kept beside the target so a rewrite defect is
    /// recoverable.
    public var backupSuffix: String

    public init(
        name: String,
        command: String,
        arguments: [String] = ["--mcp"],
        backupSuffix: String? = nil
    ) {
        self.name = name
        self.command = command
        self.arguments = arguments
        self.backupSuffix = backupSuffix ?? ".\(name)-mcp-backup"
    }
}

//
//  Client.swift
//  MCPClientInstall
//
//  Catalogue of desktop MCP clients the installer knows how to write into, with
//  their display names, config paths, and pasteable snippet formats. Restart /
//  verify copy stays product-agnostic so a host can append its own wording.
//

import Foundation

/// An MCP desktop client this package can install a server entry into.
public enum MCPDesktopClient: String, CaseIterable, Hashable, Identifiable, Sendable {
    case claudeDesktop
    case claudeCode
    case codex
    case cursor

    public var id: String { rawValue }

    /// The client's human-facing name, shown as a tab title or button label.
    public var displayName: String {
        switch self {
        case .claudeDesktop: "Claude Desktop"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }

    /// How this client's on-disk config is shaped.
    public enum Format: Sendable {
        /// A top-level `mcpServers` JSON object (Claude Desktop, Cursor, and the
        /// JSON file Claude Code also reads at `~/.claude.json`).
        case json
        /// A `[mcp_servers.<name>]` TOML table (Codex).
        case toml
    }

    /// The on-disk format this client uses.
    ///
    /// Claude Code's *CLI* prefers `claude mcp add …`, but its settings file at
    /// `~/.claude.json` is the same JSON shape as Claude Desktop. This package
    /// installs into that file, so Claude Code is `.json` here.
    public var format: Format {
        switch self {
        case .claudeDesktop, .claudeCode, .cursor: .json
        case .codex: .toml
        }
    }

    /// Default config-file location, for a "paste into …" hint. May not exist yet.
    public var configPath: String {
        switch self {
        case .claudeDesktop: "~/Library/Application Support/Claude/claude_desktop_config.json"
        case .claudeCode: "~/.claude.json"
        case .codex: "~/.codex/config.toml"
        case .cursor: "~/.cursor/mcp.json"
        }
    }

    /// How to make the client pick up a newly written server entry.
    public var restartHint: String {
        switch self {
        case .claudeDesktop: "Quit Claude Desktop with \u{2318}Q and reopen it."
        case .claudeCode: "Start a fresh Claude Code session (or run /mcp)."
        case .codex: "Restart Codex."
        case .cursor: "Reload Cursor (or toggle the server in its MCP settings)."
        }
    }

    /// An optional tip for confirming the server connected, parameterised on the
    /// server name. `nil` when there is nothing client-specific worth saying.
    public func verifyHint(serverName: String) -> String? {
        switch self {
        case .claudeDesktop:
            "If it doesn't show up, check Claude Desktop's logs in ~/Library/Logs/Claude/."

        case .claudeCode:
            "Confirm it connected with `claude mcp list` or `claude mcp get \(serverName)`."

        case .codex, .cursor:
            nil
        }
    }

    /// A ready-to-paste config snippet (JSON object or TOML table) for the manual
    /// "edit the file yourself" fallback. Always matches ``format`` — Claude Code
    /// gets the JSON block that belongs in `~/.claude.json`, not a CLI command.
    public func configSnippet(for server: MCPServerSpec) -> String {
        switch format {
        case .json:
            let config: [String: Any] = [
                "mcpServers": [
                    server.name: ["command": server.command, "args": server.arguments]
                ]
            ]
            let data = (try? JSONSerialization.data(
                withJSONObject: config, options: [.prettyPrinted, .sortedKeys]
            )) ?? Data("{}".utf8)
            return String(data: data, encoding: .utf8) ?? "{}"

        case .toml:
            return MCPClientInstall.codexServerBlock(for: server)
        }
    }
}

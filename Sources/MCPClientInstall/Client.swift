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

    /// A configuration location relative to a caller-supplied home directory.
    ///
    /// `fallbackDirectoryComponents` supports sandboxed apps that ask the user for
    /// a visible parent when the preferred hidden directory does not exist yet.
    public struct ConfigurationLocation: Equatable, Sendable {
        public let directoryComponents: [String]
        public let fallbackDirectoryComponents: [String]
        public let fileName: String
        public let format: MCPClientInstall.ConfigurationFormat

        public init(
            directoryComponents: [String],
            fallbackDirectoryComponents: [String],
            fileName: String,
            format: MCPClientInstall.ConfigurationFormat
        ) {
            self.directoryComponents = directoryComponents
            self.fallbackDirectoryComponents = fallbackDirectoryComponents
            self.fileName = fileName
            self.format = format
        }

        public func directory(relativeTo homeDirectory: URL) -> URL {
            directoryComponents.reduce(homeDirectory) {
                $0.appendingPathComponent($1, isDirectory: true)
            }
        }

        public func fallbackDirectory(relativeTo homeDirectory: URL) -> URL {
            fallbackDirectoryComponents.reduce(homeDirectory) {
                $0.appendingPathComponent($1, isDirectory: true)
            }
        }
    }

    /// The canonical on-disk location and representation for this client.
    public var configurationLocation: ConfigurationLocation {
        switch self {
        case .claudeDesktop:
            ConfigurationLocation(
                directoryComponents: ["Library", "Application Support", "Claude"],
                fallbackDirectoryComponents: ["Library", "Application Support"],
                fileName: "claude_desktop_config.json",
                format: .json
            )
        case .claudeCode:
            ConfigurationLocation(
                directoryComponents: [], fallbackDirectoryComponents: [],
                fileName: ".claude.json", format: .json
            )
        case .codex:
            ConfigurationLocation(
                directoryComponents: [".codex"], fallbackDirectoryComponents: [],
                fileName: "config.toml", format: .codexTOML
            )
        case .cursor:
            ConfigurationLocation(
                directoryComponents: [".cursor"], fallbackDirectoryComponents: [],
                fileName: "mcp.json", format: .json
            )
        }
    }

    public var format: MCPClientInstall.ConfigurationFormat { configurationLocation.format }

    /// Default config-file location, for a "paste into …" hint. May not exist yet.
    public var configPath: String {
        (["~"] + configurationLocation.directoryComponents + [configurationLocation.fileName])
            .joined(separator: "/")
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

        case .codexTOML:
            return MCPClientInstall.codexServerBlock(for: server)
        }
    }
}

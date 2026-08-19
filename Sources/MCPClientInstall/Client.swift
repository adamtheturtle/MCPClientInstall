//
//  Client.swift
//  MCPClientInstall
//
//  Catalogue of desktop MCP clients the installer knows how to write into, with
//  their display names, config paths, and pasteable snippet formats. Restart /
//  verify copy stays product-agnostic so a host can append its own wording.
//

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// An MCP desktop client this package can install a server entry into.
public enum MCPDesktopClient: String, CaseIterable, Hashable, Identifiable, Sendable {
    case claudeDesktop
    case claudeCode
    case codex
    case cursor

    public enum ConfigurationLocationError: Error, Equatable, Sendable {
        case unsafeDirectoryComponent(String)
        case nonFileHomeURL(URL)
        case unsafeFileName(String)
        case outsideHomeDirectory(URL)
    }

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
        ) throws {
            guard Self.isSafeDirectoryComponent(fileName) else {
                throw ConfigurationLocationError.unsafeFileName(fileName)
            }
            self.directoryComponents = directoryComponents
            self.fallbackDirectoryComponents = fallbackDirectoryComponents
            self.fileName = fileName
            self.format = format
        }

        fileprivate init(
            validatedDirectoryComponents directoryComponents: [String],
            fallbackDirectoryComponents: [String],
            fileName: String,
            format: MCPClientInstall.ConfigurationFormat
        ) {
            self.directoryComponents = directoryComponents
            self.fallbackDirectoryComponents = fallbackDirectoryComponents
            self.fileName = fileName
            self.format = format
        }

        public func directory(relativeTo homeDirectory: URL) throws -> URL {
            try safeDirectory(components: directoryComponents, relativeTo: homeDirectory)
        }

        public func fallbackDirectory(relativeTo homeDirectory: URL) throws -> URL {
            try safeDirectory(components: fallbackDirectoryComponents, relativeTo: homeDirectory)
        }

        public func file(relativeTo homeDirectory: URL) throws -> URL {
            try directory(relativeTo: homeDirectory).appendingPathComponent(fileName)
        }

        private func safeDirectory(components: [String], relativeTo homeDirectory: URL) throws -> URL {
            guard homeDirectory.isFileURL else {
                throw ConfigurationLocationError.nonFileHomeURL(homeDirectory)
            }
            for component in components where !Self.isSafeDirectoryComponent(component) {
                throw ConfigurationLocationError.unsafeDirectoryComponent(component)
            }
            let home = homeDirectory.standardizedFileURL
            let candidate = components.reduce(home) {
                $0.appendingPathComponent($1, isDirectory: true)
            }.standardizedFileURL
            let homePath = home.path.hasSuffix("/") ? home.path : home.path + "/"
            guard candidate == home || candidate.path.hasPrefix(homePath) else {
                throw ConfigurationLocationError.outsideHomeDirectory(candidate)
            }
            try Self.validateNoFollowTraversal(components: components, home: home)
            return candidate
        }

        private static func validateNoFollowTraversal(
            components: [String],
            home: URL
        ) throws {
            var descriptor = open(home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if descriptor < 0, errno == ENOENT { return }
            guard descriptor >= 0 else {
                throw ConfigurationLocationError.outsideHomeDirectory(home)
            }
            defer { close(descriptor) }

            for component in components {
                let child = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                if child >= 0 {
                    close(descriptor)
                    descriptor = child
                } else if errno == ENOENT {
                    return
                } else {
                    throw ConfigurationLocationError.unsafeDirectoryComponent(component)
                }
            }
        }

        private static func isSafeDirectoryComponent(_ component: String) -> Bool {
            !component.isEmpty
                && component != "."
                && component != ".."
                && !component.contains("\0")
                && !component.contains("/")
                && !component.contains("\\")
        }
    }

    /// The canonical on-disk location and representation for this client.
    public var configurationLocation: ConfigurationLocation {
        switch self {
        case .claudeDesktop:
            ConfigurationLocation(
                validatedDirectoryComponents: ["Library", "Application Support", "Claude"],
                fallbackDirectoryComponents: ["Library", "Application Support"],
                fileName: "claude_desktop_config.json",
                format: .json
            )
        case .claudeCode:
            ConfigurationLocation(
                validatedDirectoryComponents: [], fallbackDirectoryComponents: [],
                fileName: ".claude.json", format: .json
            )
        case .codex:
            ConfigurationLocation(
                validatedDirectoryComponents: [".codex"], fallbackDirectoryComponents: [],
                fileName: "config.toml", format: .codexTOML
            )
        case .cursor:
            ConfigurationLocation(
                validatedDirectoryComponents: [".cursor"], fallbackDirectoryComponents: [],
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
            "Confirm it connected with `claude mcp list`."

        case .codex, .cursor:
            nil
        }
    }

    /// A ready-to-paste config snippet (JSON object or TOML table) for the manual
    /// "edit the file yourself" fallback. Always matches ``format`` — Claude Code
    /// gets the JSON block that belongs in `~/.claude.json`, not a CLI command.
    public func configSnippet(for server: MCPServerSpec) throws -> String {
        try server.validate()
        switch format {
        case .json:
            let config: [String: Any] = [
                "mcpServers": [
                    server.name: ["command": server.command, "args": server.arguments]
                ]
            ]
            let data = try JSONSerialization.data(
                withJSONObject: config, options: [.prettyPrinted, .sortedKeys]
            )
            guard let text = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding)
            }
            return text

        case .codexTOML:
            return MCPClientInstall.codexServerBlock(for: server)
        }
    }
}

//
//  JSONConfig.swift
//  MCPClientInstall
//
//  Merge a server entry into a Claude Desktop / Claude Code / Cursor JSON config
//  without clobbering unrelated keys or a mistyped `mcpServers` value.
//

import Foundation

public extension MCPClientInstall {
    /// Thrown when an existing JSON config's `mcpServers` value is present but not
    /// an object, so merging would silently destroy it.
    enum JSONConfigError: Error, Equatable, Sendable {
        case incompatibleMCPServers
        case incompatibleServer(name: String)
    }

    /// Result of merging a server into a JSON root object.
    struct JSONMergeResult: @unchecked Sendable {
        public var root: [String: Any]
        public var alreadyPresent: Bool
    }

    /// Adds (or updates) `server` under `root["mcpServers"]`, preserving every other
    /// key. Throws ``JSONConfigError/incompatibleMCPServers`` when `mcpServers` is
    /// present but not a JSON object.
    static func jsonConfigByAddingServer(
        to root: [String: Any],
        server: MCPServerSpec
    ) throws -> JSONMergeResult {
        var root = root
        var servers: [String: Any]
        if let existing = root["mcpServers"] {
            guard let object = existing as? [String: Any] else {
                throw JSONConfigError.incompatibleMCPServers
            }

            servers = object
        } else {
            servers = [:]
        }

        let alreadyPresent: Bool
        var serverEntry: [String: Any]
        if let existing = servers[server.name] {
            guard let object = existing as? [String: Any],
                  object["command"] is String,
                  object["args"] == nil || object["args"] is [String]
            else {
                throw JSONConfigError.incompatibleServer(name: server.name)
            }
            alreadyPresent = true
            serverEntry = object
        } else {
            alreadyPresent = false
            serverEntry = [:]
        }
        serverEntry["command"] = server.command
        serverEntry["args"] = server.arguments
        servers[server.name] = serverEntry
        root["mcpServers"] = servers
        return JSONMergeResult(root: root, alreadyPresent: alreadyPresent)
    }

    /// Reads and parses an existing JSON config, returning an empty object when the
    /// file is absent or whitespace-only. A malformed file throws so we don't
    /// silently clobber it.
    static func existingJSON(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }

        let data = try Data(contentsOf: url)
        // Whitespace-only counts as blank. A file holding just a newline is empty
        // to the person who made it, and rejecting it as corrupt would refuse to
        // write a config the installer could perfectly well create.
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }

        return object
    }

    /// Pretty-printed JSON bytes for `root`, with sorted keys for a stable diff.
    static func prettyJSONData(from root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}

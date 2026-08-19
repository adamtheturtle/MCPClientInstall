//
//  JSONConfig.swift
//  MCPClientInstall
//
//  Merge a server entry into a Claude Desktop / Claude Code / Cursor JSON config
//  without clobbering unrelated keys or a mistyped `mcpServers` value.
//

import CoreFoundation
import Foundation

public extension MCPClientInstall {
    static let maxConfigurationFileBytes = 4 * 1024 * 1024

    enum ConfigurationReadError: Error, Equatable, Sendable {
        case tooLarge(limit: Int)
        case unsafePath(ConfigPathKind)
    }

    /// Thrown when an existing JSON config's `mcpServers` value is present but not
    /// an object, so merging would silently destroy it.
    enum JSONConfigError: Error, Equatable, Sendable {
        case incompatibleMCPServers
        case incompatibleServer(name: String)
        case invalidJSONObject
        case duplicateKey(String)
    }

    /// Result of merging a server into a JSON root object.
    struct JSONMergeResult {
        public var root: [String: Any]
        public var alreadyPresent: Bool
    }

    /// Adds (or updates) `server` under `root["mcpServers"]`, preserving every other
    /// key. Throws ``JSONConfigError/incompatibleMCPServers`` when `mcpServers` is
    /// present but not a JSON object.
    static func jsonConfigByAddingServer(
        to root: [String: Any],
        server: MCPServerSpec,
    ) throws -> JSONMergeResult {
        try server.validate()
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
        let kind = configPathKind(at: url)
        guard kind != .absent else { return [:] }
        guard kind == .regularFile else { throw ConfigurationReadError.unsafePath(kind) }

        let data = try boundedConfigurationData(at: url)
        // Whitespace-only counts as blank. A file holding just a newline is empty
        // to the person who made it, and rejecting it as corrupt would refuse to
        // write a config the installer could perfectly well create.
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        try rejectDuplicateJSONKeys(in: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }

        return object
    }

    /// Pretty-printed JSON bytes for `root`, with sorted keys for a stable diff.
    static func prettyJSONData(from root: [String: Any]) throws -> Data {
        var ancestors: Set<ObjectIdentifier> = []
        guard hasBoundedAcyclicContainers(root, depth: 0, ancestors: &ancestors),
              JSONSerialization.isValidJSONObject(root)
        else {
            throw JSONConfigError.invalidJSONObject
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private static func hasBoundedAcyclicContainers(
        _ value: Any,
        depth: Int,
        ancestors: inout Set<ObjectIdentifier>
    ) -> Bool {
        guard depth <= 128 else { return false }

        if let dictionary = value as? NSMutableDictionary {
            return validateFoundationDictionary(dictionary, depth: depth, ancestors: &ancestors)
        }
        if let array = value as? NSMutableArray {
            return validateFoundationArray(array, depth: depth, ancestors: &ancestors)
        }
        if let dictionary = value as? [String: Any] {
            for child in dictionary.values {
                guard hasBoundedAcyclicContainers(child, depth: depth + 1, ancestors: &ancestors) else {
                    return false
                }
            }
            return true
        }
        if let array = value as? [Any] {
            for child in array {
                guard hasBoundedAcyclicContainers(child, depth: depth + 1, ancestors: &ancestors) else {
                    return false
                }
            }
            return true
        }
        if let dictionary = value as? NSDictionary {
            return validateFoundationDictionary(dictionary, depth: depth, ancestors: &ancestors)
        }
        if let array = value as? NSArray {
            return validateFoundationArray(array, depth: depth, ancestors: &ancestors)
        }

        return true
    }

    private static func validateFoundationDictionary(
        _ dictionary: NSDictionary,
        depth: Int,
        ancestors: inout Set<ObjectIdentifier>
    ) -> Bool {
        let identity = ObjectIdentifier(dictionary)
        guard ancestors.insert(identity).inserted else { return false }
        defer { ancestors.remove(identity) }
        let rawDictionary = unsafeBitCast(dictionary, to: CFDictionary.self)
        let count = CFDictionaryGetCount(rawDictionary)
        var keys = [UnsafeRawPointer?](repeating: nil, count: count)
        var values = [UnsafeRawPointer?](repeating: nil, count: count)
        CFDictionaryGetKeysAndValues(rawDictionary, &keys, &values)
        for index in 0 ..< count {
            guard let keyPointer = keys[index], let valuePointer = values[index] else { return false }
            let key = Unmanaged<AnyObject>.fromOpaque(keyPointer).takeUnretainedValue()
            let child = Unmanaged<AnyObject>.fromOpaque(valuePointer).takeUnretainedValue()
            guard key is String,
                  hasBoundedAcyclicContainers(child, depth: depth + 1, ancestors: &ancestors)
            else { return false }
        }
        return true
    }

    private static func validateFoundationArray(
        _ array: NSArray,
        depth: Int,
        ancestors: inout Set<ObjectIdentifier>
    ) -> Bool {
        let identity = ObjectIdentifier(array)
        guard ancestors.insert(identity).inserted else { return false }
        defer { ancestors.remove(identity) }
        let rawArray = unsafeBitCast(array, to: CFArray.self)
        for index in 0 ..< CFArrayGetCount(rawArray) {
            guard let pointer = CFArrayGetValueAtIndex(rawArray, index) else { return false }
            let child = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
            guard hasBoundedAcyclicContainers(child, depth: depth + 1, ancestors: &ancestors) else {
                return false
            }
        }
        return true
    }

    static func boundedConfigurationData(at url: URL) throws -> Data {
        let kind = configPathKind(at: url)
        guard kind == .regularFile else {
            throw ConfigurationReadError.unsafePath(kind)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maxConfigurationFileBytes {
            let remaining = maxConfigurationFileBytes + 1 - data.count
            guard let chunk = try handle.read(upToCount: min(64 * 1024, remaining)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maxConfigurationFileBytes else {
            throw ConfigurationReadError.tooLarge(limit: maxConfigurationFileBytes)
        }
        return data
    }
}

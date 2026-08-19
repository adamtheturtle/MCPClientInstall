//
//  ServerSpec.swift
//  MCPClientInstall
//
//  The identity of the MCP server entry being installed into a desktop client's
//  config. Parameterises every path that used to hard-code a product name, so
//  any host app can reuse the merge/write machinery unchanged.
//

import Foundation

/// The server entry written into each client's config file.
///
/// Every field is part of the on-disk payload or of user-facing messaging, so a
/// host app supplies all of them and the package never invents a product identity.
public struct MCPServerSpec: Sendable, Equatable {
    public enum ValidationError: Error, Equatable, Sendable {
        case blankName
        case blankCommand
        case commandContainsNUL
        case argumentContainsNUL(index: Int)
        case unsafeBackupSuffix(String)
    }

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
        self.backupSuffix = backupSuffix ?? Self.defaultBackupSuffix(for: name)
    }

    func validate() throws {
        try validateConfiguration()
        try validateBackupPolicy()
    }

    func validateConfiguration() throws {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError.blankName
        }
        if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError.blankCommand
        }
        if command.contains("\0") {
            throw ValidationError.commandContainsNUL
        }
        if let index = arguments.firstIndex(where: { $0.contains("\0") }) {
            throw ValidationError.argumentContainsNUL(index: index)
        }
    }

    func validateBackupPolicy() throws {
        guard isSafeFilenameSuffix(backupSuffix) else {
            throw ValidationError.unsafeBackupSuffix(backupSuffix)
        }
    }

    private static func defaultBackupSuffix(for name: String) -> String {
        let encoded = name.utf8.map { byte -> String in
            if byte.isASCIIAlphaNumeric || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_") {
                return String(Unicode.Scalar(byte))
            }
            return String(format: "_%02X", byte)
        }.joined()
        return ".\(encoded)-mcp-backup"
    }
}

func isSafeFilenameSuffix(_ suffix: String) -> Bool {
    !suffix.isEmpty
        && suffix != "."
        && suffix != ".."
        && !suffix.contains("\0")
        && !suffix.contains("/")
        && !suffix.contains("\\")
}

private extension UInt8 {
    var isASCIIAlphaNumeric: Bool {
        (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(self)
            || (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains(self)
            || (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(self)
    }
}

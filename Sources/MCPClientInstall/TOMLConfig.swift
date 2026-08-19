import Foundation
import TOML

public extension MCPClientInstall {
    /// How a server name is already declared in a Codex configuration.
    enum TOMLDeclaration: Equatable, Sendable {
        case notDeclared
        case table
        case other
    }

    /// The result of inspecting a Codex configuration.
    struct TOMLScan: Sendable {
        public let declaration: TOMLDeclaration
        public let lines: [String]
        public let tableLineRange: Range<Int>?
    }

    /// An error raised when a TOML file cannot be extended or safely rewritten.
    struct TOMLConfigError: LocalizedError, Sendable {
        public let errorDescription: String?

        public init(_ description: String) {
            errorDescription = description
        }
    }

    /// Encodes a value as a TOML basic string.
    static func tomlBasicString(_ value: String) -> String {
        let scalars = value.unicodeScalars
        var escaped = "\""
        escaped.reserveCapacity(value.utf8.count + 2)
        for scalar in scalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\u{08}": escaped += "\\b"
            case "\t": escaped += "\\t"
            case "\n": escaped += "\\n"
            case "\u{0C}": escaped += "\\f"
            case "\r": escaped += "\\r"
            default:
                if scalar.value < 0x20 || (0x7F ... 0x9F).contains(scalar.value) {
                    escaped += String(format: "\\u%04X", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        escaped += "\""
        return escaped
    }

    /// A complete Codex server table.
    static func codexServerBlock(for server: MCPServerSpec) -> String {
        let key = tomlBareKey(server.name) ? server.name : tomlBasicString(server.name)
        let arguments = server.arguments.map(tomlBasicString).joined(separator: ", ")
        return """
        [mcp_servers.\(key)]
        command = \(tomlBasicString(server.command))
        args = [\(arguments)]

        """
    }

    static func codexServerIsConfigured(_ server: MCPServerSpec, in text: String) -> Bool {
        guard let document = try? TOMLDecoder().decode(CodexServerDocument.self, from: text),
              let configured = document.servers?[server.name]
        else { return false }
        return configured.command == server.command && configured.arguments == server.arguments
    }

    static func validateCodexTOML(_ text: String) throws {
        _ = try TOMLDecoder().decode(TOMLValidationDocument.self, from: text)
    }

    /// Scans for declarations of `serverName` without interpreting apparent
    /// headers inside multiline strings or arrays.
    static func scanCodexConfig(_ text: String, serverName: String) -> TOMLScan {
        // Normalize physical lines before parsing. Foundation's character-set
        // treatment of CR differs across platforms; doing this explicitly keeps
        // the scanner byte-for-byte equivalent on Darwin and Linux.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        var currentTable: [String] = []
        var tableRanges: [Range<Int>] = []
        var hasUnsafeDeclaration = false
        var state = TOMLLineState()

        for index in lines.indices {
            let scannedLine = tomlScanningLine(lines[index], at: index)
            let continuation = state.isInsideMultilineConstruct
            state.consume(scannedLine)
            if continuation { continue }

            let line = stripCarriageReturn(scannedLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                guard let path = tomlHeaderKeyPath(line) else { continue }
                currentTable = path
                guard path.starts(with: ["mcp_servers", serverName]) else { continue }
                if path.count == 2, !line.hasPrefix("[[") {
                    var bodyState = state
                    tableRanges.append(tableBody(startingAt: index, in: lines, state: &bodyState))
                } else if path.count < 3 || path[2] == "command" || path[2] == "args" {
                    hasUnsafeDeclaration = true
                }
                continue
            }

            guard let path = tomlKeyValueKeyPath(line) else { continue }
            let fullPath = currentTable + path
            let serverPath = ["mcp_servers", serverName]
            if serverPath.starts(with: fullPath), fullPath.count < serverPath.count {
                hasUnsafeDeclaration = true
            }
            if fullPath.starts(with: ["mcp_servers", serverName]),
               currentTable != ["mcp_servers", serverName] {
                let relativePath = Array(fullPath.dropFirst(serverPath.count))
                guard let leadingKey = relativePath.first else {
                    // The whole server is declared as one inline value, such as
                    // ``mcp_servers.demo = { ... }``, which cannot be rewritten
                    // key by key.
                    hasUnsafeDeclaration = true
                    continue
                }
                if leadingKey == "command" || leadingKey == "args",
                   currentTable != serverPath || path.count > 1 {
                    hasUnsafeDeclaration = true
                }
            }
        }

        guard !hasUnsafeDeclaration, tableRanges.count == 1 else {
            let declaration: TOMLDeclaration =
                hasUnsafeDeclaration || !tableRanges.isEmpty ? .other : .notDeclared
            return TOMLScan(declaration: declaration, lines: lines, tableLineRange: nil)
        }
        return TOMLScan(declaration: .table, lines: lines, tableLineRange: tableRanges[0])
    }

    /// Returns the first definite structural fault visible to the conservative
    /// line scanner. This deliberately isn't a complete TOML validator.
    static func codexConfigStructuralProblem(in text: String) -> String? {
        var state = TOMLLineState()
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        for (offset, rawLine) in lines.enumerated() {
            let scannedLine = tomlScanningLine(rawLine, at: offset)
            let continuation = state.isInsideMultilineConstruct
            state.consume(scannedLine)
            if continuation { continue }
            let line = stripCarriageReturn(scannedLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                if tomlHeaderKeyPath(line) == nil {
                    return "line \(offset + 1) has a malformed table header"
                }
            } else if tomlKeyValueKeyPath(line) == nil {
                return "line \(offset + 1) is neither a comment, a table header, nor a setting"
            }
        }
        return state.isInsideMultilineConstruct
            ? "it ends inside an unclosed string or array"
            : nil
    }

    /// Adds or updates a server table while retaining unrelated settings and the
    /// source file's line-ending convention.
    static func codexConfigByAddingServer(
        to text: String,
        server: MCPServerSpec
    ) throws -> (text: String, alreadyPresent: Bool) {
        try server.validate()
        do {
            _ = try TOMLDecoder().decode(TOMLValidationDocument.self, from: text)
        } catch {
            throw TOMLConfigError("The existing config is not valid TOML: \(error.localizedDescription)")
        }

        let scan = scanCodexConfig(text, serverName: server.name)
        let newline = dominantLineEnding(of: text)
        let block = codexServerBlock(for: server)
            .components(separatedBy: "\n")
            .joined(separator: newline)

        let result: (text: String, alreadyPresent: Bool)
        switch scan.declaration {
        case .notDeclared:
            if let problem = codexConfigStructuralProblem(in: text) {
                throw TOMLConfigError("The existing config is not valid TOML: \(problem).")
            }
            result = (text.isEmpty ? block : text + newline + block, false)

        case .table:
            guard let range = scan.tableLineRange else {
                throw TOMLConfigError("The server table could not be located.")
            }
            let physicalLines = tomlPhysicalLines(text)
            guard physicalLines.count == scan.lines.count else {
                throw TOMLConfigError("The server table's physical lines could not be located.")
            }
            var body = physicalLines[range].map(\.content)
            if range.lowerBound == 0, text.hasPrefix("\u{FEFF}"), !body.isEmpty {
                body[0] = String(body[0].dropFirst())
            }
            var replacement = try codexTableReplacement(body: body, server: server)
                .joined(separator: newline)
            if range.lowerBound == 0, text.hasPrefix("\u{FEFF}") {
                replacement = "\u{FEFF}" + replacement
            }
            let prefix = physicalLines[..<range.lowerBound].map(\.text).joined()
            let suffix = physicalLines[range.upperBound...].map(\.text).joined()
            result = (prefix + replacement + suffix, true)

        case .other:
            throw TOMLConfigError(
                "The existing config declares \(server.name) in a form that cannot be safely rewritten."
            )
        }

        do {
            try validateCodexTOML(result.text)
        } catch {
            throw TOMLConfigError("The updated config is not valid TOML: \(error.localizedDescription)")
        }
        return result
    }

    /// The dominant physical line ending, used to avoid noisy whole-file diffs.
    static func dominantLineEnding(of text: String) -> String {
        let crlf = text.components(separatedBy: "\r\n").count - 1
        let lf = text.components(separatedBy: "\n").count - 1 - crlf
        return crlf > lf ? "\r\n" : "\n"
    }

    private static func codexTableReplacement(
        body: [String],
        server: MCPServerSpec
    ) throws -> [String] {
        let block = codexServerBlock(for: server).components(separatedBy: "\n")
        guard body.count > 1 else { return block }

        var retained: [RetainedLine] = []
        var state = TOMLLineState()
        var removingOwnedValue = false
        for line in body.dropFirst() {
            if !state.isInsideMultilineConstruct,
               let path = tomlKeyValueKeyPath(line.trimmingCharacters(in: .whitespaces)),
               path == ["command"] || path == ["args"] {
                removingOwnedValue = true
            }

            let insideValue = state.isInsideMultilineConstruct
            state.consume(line)
            if !removingOwnedValue {
                retained.append(RetainedLine(text: line, insideValue: insideValue))
            } else if !state.isInsideMultilineConstruct {
                removingOwnedValue = false
            }
        }
        guard !removingOwnedValue else {
            throw TOMLConfigError("The existing server table contains an unclosed value.")
        }

        // The spacer appended below separates this table from the next one. Any
        // blank line already at the end of the table is that same separator from
        // an earlier rewrite, so keeping it as well would grow the file by a
        // line on every update.
        while let last = retained.last,
              !last.insideValue,
              last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            retained.removeLast()
        }

        var result = Array(block.dropLast())
        result.append(contentsOf: retained.map(\.text))
        result.append("")
        return result
    }

    /// A line kept from an existing server table, and whether its content lies
    /// inside a multiline value rather than being structural.
    private struct RetainedLine {
        let text: String
        let insideValue: Bool
    }

    private static func tomlBareKey(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains($0)
                || (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains($0)
                || (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0)
                || $0 == UInt8(ascii: "_")
                || $0 == UInt8(ascii: "-")
        }
    }

    private static func stripCarriageReturn(_ line: String) -> String {
        line.hasSuffix("\r") ? String(line.dropLast()) : line
    }

    private static func tableBody(
        startingAt header: Int,
        in lines: [String],
        state: inout TOMLLineState
    ) -> Range<Int> {
        var index = header + 1
        while index < lines.count {
            if !state.isInsideMultilineConstruct,
               stripCarriageReturn(lines[index]).trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                break
            }
            state.consume(lines[index])
            index += 1
        }
        return header ..< index
    }
}

private struct TOMLValidationDocument: Decodable {}

private struct CodexServerDocument: Decodable {
    let servers: [String: CodexServerValues]?

    private enum CodingKeys: String, CodingKey {
        case servers = "mcp_servers"
    }
}

private struct CodexServerValues: Decodable {
    let command: String?
    let arguments: [String]?

    private enum CodingKeys: String, CodingKey {
        case command
        case arguments = "args"
    }
}

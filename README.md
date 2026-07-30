# MCPClientInstall

Safe, non-destructive editing of MCP desktop-client configuration files in Swift.

[Documentation](https://swiftpackageindex.com/adamtheturtle/MCPClientInstall/documentation/mcpclientinstall) |
[Swift Package Index](https://swiftpackageindex.com/adamtheturtle/MCPClientInstall)

MCPClientInstall adds or updates a local MCP server in:

- Claude Desktop, Claude Code, and Cursor JSON configuration
- Codex TOML configuration

It preserves unrelated settings, refuses ambiguous configuration shapes, handles
quoted TOML keys and multiline values, retains existing line endings, and can replace
files while preserving metadata and leaving a backup.

## Installation

```swift
.package(
    url: "https://github.com/adamtheturtle/MCPClientInstall.git",
    from: "0.1.0"
)
```

Add the `MCPClientInstall` product to your target.

## Usage

```swift
import MCPClientInstall

let server = MCPServerSpec(
    name: "my-server",
    command: "/usr/local/bin/my-server",
    arguments: ["--mcp"],
    productName: "My Server"
)

// JSON: Claude Desktop, Claude Code, or Cursor
let root = try MCPClientInstall.existingJSON(at: configURL)
let merged = try addingMCPServer(server, toJSON: root)
let data = try MCPClientInstall.prettyJSONData(from: merged.root)

// TOML: Codex
let existing = try String(contentsOf: configURL, encoding: .utf8)
let updated = try addingMCPServer(server, toCodexTOML: existing)
```

Writing is deliberately separate from merging, so an application can show a diff or
ask for confirmation first:

```swift
try MCPClientInstall.writeConfig(
    data,
    to: configURL,
    backupSuffix: server.backupSuffix
)
```

## Safety

MCPClientInstall does not silently replace malformed or structurally incompatible
configuration. Its file helper refuses symlinks and special files, retains metadata
when replacing an existing file, and keeps the previous contents beside the target.

Applications remain responsible for obtaining user consent and filesystem access.
The package has no UI and never searches for or modifies configuration on import.

## Requirements

- Swift 6.2+
- macOS 14+
- Linux with a Swift 6.2 toolchain

## Documentation

The package includes a DocC catalog and is configured for hosted documentation on
Swift Package Index.

## License

MIT. See [LICENSE](LICENSE).

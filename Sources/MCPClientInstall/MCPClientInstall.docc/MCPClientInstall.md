# ``MCPClientInstall``

Safely add a local Model Context Protocol server to desktop-client configuration.

## Overview

MCPClientInstall edits the JSON configuration used by Claude Desktop, Claude Code,
and Cursor, and the TOML configuration used by Codex. Existing keys are retained.
Ambiguous or incompatible declarations are refused instead of overwritten.

Use ``MCPServerSpec`` to describe a server, then merge it with
``MCPClientInstall/jsonConfigByAddingServer(to:server:)`` or
``MCPClientInstall/codexConfigByAddingServer(to:server:)``.

The package also provides guarded file replacement through
``MCPClientInstall/writeConfig(_:to:backupSuffix:)``.

## Topics

### Server identity

- ``MCPServerSpec``
- ``MCPDesktopClient``

### JSON

- ``MCPClientInstall/jsonConfigByAddingServer(to:server:)``
- ``MCPClientInstall/existingJSON(at:)``
- ``MCPClientInstall/prettyJSONData(from:)``

### Codex TOML

- ``MCPClientInstall/codexConfigByAddingServer(to:server:)``
- ``MCPClientInstall/scanCodexConfig(_:serverName:)``
- ``MCPClientInstall/codexServerBlock(for:)``

### Safe file replacement

- ``MCPClientInstall/writeConfig(_:to:backupSuffix:)``
- ``MCPClientInstall/configPathKind(at:)``

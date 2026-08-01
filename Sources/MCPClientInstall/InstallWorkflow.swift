import Foundation

public extension MCPClientInstall {
    /// The configuration representation used by a client.
    enum ConfigurationFormat: Equatable, Sendable {
        case json
        case codexTOML
    }

    /// A product-neutral failure that a host can map to its own localized copy.
    enum InstallWorkflowError: Error, Equatable, Sendable {
        case unsafePath(url: URL, kind: ConfigPathKind)
        case readFailed(url: URL, detail: String)
        case configurationTooLarge(url: URL, limit: Int)
        case invalidConfiguration(url: URL, detail: String)
        case serializationFailed(url: URL, detail: String)
        case writeFailed(url: URL, detail: String)
        case verificationFailed(url: URL, backupURL: URL?)
        case backupUnavailable(url: URL)
        case displacedFileExists(url: URL)
        case restorationFailed(url: URL, detail: String)
    }

    /// The complete bytes prepared for a safe replacement.
    struct PreparedConfigUpdate: Sendable {
        public let data: Data
        public let format: ConfigurationFormat
        public let alreadyPresent: Bool
    }

    /// The outcome of an installed and read-back-verified server entry.
    struct InstallWorkflowResult: Equatable, Sendable {
        public let alreadyPresent: Bool
        public let backupURL: URL?
    }

    /// The outcome of restoring a backup. When a current file existed, it remains
    /// beside the restored file at `displacedURL` for further recovery.
    struct RestoreWorkflowResult: Equatable, Sendable {
        public let displacedURL: URL?
    }

    /// Prepares a complete JSON or Codex TOML update without writing it.
    static func prepareServerUpdate(
        _ server: MCPServerSpec,
        format: ConfigurationFormat,
        at url: URL,
    ) throws -> PreparedConfigUpdate {
        let kind = configPathKind(at: url)
        guard kind == .absent || kind == .regularFile else {
            throw InstallWorkflowError.unsafePath(url: url, kind: kind)
        }

        switch format {
        case .json:
            do {
                let root = try existingJSON(at: url)
                let merged = try jsonConfigByAddingServer(to: root, server: server)
                return try PreparedConfigUpdate(
                    data: prettyJSONData(from: merged.root),
                    format: format,
                    alreadyPresent: merged.alreadyPresent,
                )
            } catch let error as JSONConfigError {
                throw InstallWorkflowError.invalidConfiguration(url: url, detail: String(describing: error))
            } catch let ConfigurationReadError.tooLarge(limit) {
                throw InstallWorkflowError.configurationTooLarge(url: url, limit: limit)
            } catch let error as CocoaError {
                throw InstallWorkflowError.invalidConfiguration(url: url, detail: error.localizedDescription)
            } catch {
                throw InstallWorkflowError.serializationFailed(url: url, detail: error.localizedDescription)
            }

        case .codexTOML:
            let text: String
            do {
                text = try existingTOML(at: url)
            } catch let ConfigurationReadError.tooLarge(limit) {
                throw InstallWorkflowError.configurationTooLarge(url: url, limit: limit)
            } catch {
                throw InstallWorkflowError.readFailed(url: url, detail: error.localizedDescription)
            }
            do {
                let merged = try codexConfigByAddingServer(to: text, server: server)
                return PreparedConfigUpdate(
                    data: Data(merged.text.utf8),
                    format: format,
                    alreadyPresent: merged.alreadyPresent,
                )
            } catch {
                throw InstallWorkflowError.invalidConfiguration(url: url, detail: error.localizedDescription)
            }
        }
    }

    /// Prepares, safely replaces, reads back, and verifies one server entry.
    static func installServer(
        _ server: MCPServerSpec,
        format: ConfigurationFormat,
        at url: URL,
    ) throws -> InstallWorkflowResult {
        try installServer(
            server,
            format: format,
            at: url,
            verificationOverride: nil,
        )
    }

    /// Restores the side-by-side backup and retains the displaced current file.
    static func restoreBackup(
        for server: MCPServerSpec,
        at url: URL,
        displacedSuffix: String,
    ) throws -> RestoreWorkflowResult {
        let manager = FileManager.default
        let backupURL = sibling(of: url, suffix: server.backupSuffix)
        guard configPathKind(at: backupURL) == .regularFile else {
            throw InstallWorkflowError.backupUnavailable(url: backupURL)
        }

        let currentKind = configPathKind(at: url)
        guard currentKind == .absent || currentKind == .regularFile else {
            throw InstallWorkflowError.unsafePath(url: url, kind: currentKind)
        }
        guard currentKind == .regularFile else {
            do {
                try manager.moveItem(at: backupURL, to: url)
                return RestoreWorkflowResult(displacedURL: nil)
            } catch {
                throw InstallWorkflowError.restorationFailed(url: url, detail: error.localizedDescription)
            }
        }

        let displacedURL = sibling(of: url, suffix: displacedSuffix)
        guard configPathKind(at: displacedURL) == .absent else {
            throw InstallWorkflowError.displacedFileExists(url: displacedURL)
        }
        do {
            try manager.moveItem(at: url, to: displacedURL)
            do {
                try manager.moveItem(at: backupURL, to: url)
            } catch {
                try? manager.moveItem(at: displacedURL, to: url)
                throw error
            }
            return RestoreWorkflowResult(displacedURL: displacedURL)
        } catch {
            throw InstallWorkflowError.restorationFailed(url: url, detail: error.localizedDescription)
        }
    }
}

extension MCPClientInstall {
    static func installServer(
        _ server: MCPServerSpec,
        format: ConfigurationFormat,
        at url: URL,
        verificationOverride: (() -> Bool)?,
    ) throws -> InstallWorkflowResult {
        let existed = configPathKind(at: url) == .regularFile
        let prepared = try prepareServerUpdate(server, format: format, at: url)
        do {
            try writeConfig(prepared.data, to: url, backupSuffix: server.backupSuffix)
        } catch {
            throw InstallWorkflowError.writeFailed(url: url, detail: error.localizedDescription)
        }

        let verified: Bool = if let verificationOverride {
            verificationOverride()
        } else {
            verifyServer(server, format: format, at: url)
        }
        let backupURL = existed ? sibling(of: url, suffix: server.backupSuffix) : nil
        guard verified else {
            throw InstallWorkflowError.verificationFailed(url: url, backupURL: backupURL)
        }
        return InstallWorkflowResult(alreadyPresent: prepared.alreadyPresent, backupURL: backupURL)
    }

    private static func existingTOML(at url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        let data = try boundedConfigurationData(at: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }

    private static func verifyServer(
        _ server: MCPServerSpec,
        format: ConfigurationFormat,
        at url: URL,
    ) -> Bool {
        switch format {
        case .json:
            guard let root = try? existingJSON(at: url) else { return false }
            return mcpServerIsConfigured(server, inJSON: root)
        case .codexTOML:
            guard let text = try? existingTOML(at: url) else { return false }
            return mcpServerIsConfigured(server, inCodexTOML: text)
        }
    }

    private static func sibling(of url: URL, suffix: String) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + suffix)
    }
}

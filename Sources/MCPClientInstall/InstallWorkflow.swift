import Foundation

private struct InstallHooks {
    let verificationOverride: (() -> Bool)?
    let afterPrepare: (() -> Void)?
    let afterWrite: (() -> Void)?
    let removeItem: (URL) throws -> Void

    init(
        verificationOverride: (() -> Bool)?,
        afterPrepare: (() -> Void)? = nil,
        afterWrite: (() -> Void)? = nil,
        removeItem: @escaping (URL) throws -> Void
    ) {
        self.verificationOverride = verificationOverride
        self.afterPrepare = afterPrepare
        self.afterWrite = afterWrite
        self.removeItem = removeItem
    }
}

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
        case invalidServer(MCPServerSpec.ValidationError)
        case configurationChanged(url: URL)
        case multiplyLinkedConfiguration(url: URL, linkCount: UInt64)
        case lockFailed(url: URL, detail: String)
        case serializationFailed(url: URL, detail: String)
        case writeFailed(url: URL, detail: String)
        case writeCommitted(url: URL, backupURL: URL?, detail: String)
        case verificationFailed(url: URL, backupURL: URL?)
        case verificationTargetChanged(url: URL, backupURL: URL?)
        case verificationRollbackFailed(url: URL, backupURL: URL?, detail: String)
        case verificationRollbackCleanupFailed(url: URL, displacedURL: URL, detail: String)
        case backupUnavailable(url: URL)
        case invalidBackup(url: URL, detail: String)
        case displacedFileExists(url: URL)
        case unsafeSiblingSuffix(String)
        case restorationFailed(url: URL, detail: String)
        /// The backup is live at `url`, but a later durability or cleanup step
        /// failed. The previous configuration is at `displacedURL`.
        case restorationCommitted(url: URL, displacedURL: URL, detail: String)
        case restorationRollbackFailed(
            url: URL, displacedURL: URL, backupURL: URL, detail: String
        )
    }

    /// The complete bytes prepared for a safe replacement.
    struct PreparedConfigUpdate: Sendable {
        public let data: Data
        public let format: ConfigurationFormat
        public let alreadyPresent: Bool
        let sourceIdentity: ConfigurationIdentity
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
        format: ConfigurationFormat,
        at url: URL,
        displacedSuffix: String,
    ) throws -> RestoreWorkflowResult {
        try withConfigurationLock(at: url) {
            try restoreBackup(
                for: server,
                format: format,
                at: url,
                displacedSuffix: displacedSuffix,
                hooks: .init(moveItem: { try FileManager.default.moveItem(at: $0, to: $1) })
            )
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
        try installServer(server, format: format, at: url, hooks: .init(
            verificationOverride: verificationOverride,
            afterPrepare: nil,
            removeItem: { try FileManager.default.removeItem(at: $0) }
        ))
    }

    static func installServer(
        _ server: MCPServerSpec,
        format: ConfigurationFormat,
        at url: URL,
        verificationOverride: (() -> Bool)?,
        afterPrepare: @escaping () -> Void,
    ) throws -> InstallWorkflowResult {
        try installServer(server, format: format, at: url, hooks: .init(
            verificationOverride: verificationOverride,
            afterPrepare: afterPrepare,
            removeItem: { try FileManager.default.removeItem(at: $0) }
        ))
    }

    static func installServer(
        _ server: MCPServerSpec,
        format: ConfigurationFormat,
        at url: URL,
        verificationOverride: (() -> Bool)?,
        removeItem: @escaping (URL) throws -> Void,
    ) throws -> InstallWorkflowResult {
        try installServer(server, format: format, at: url, hooks: .init(
            verificationOverride: verificationOverride,
            removeItem: removeItem
        ))
    }

    static func installServer(
        _ server: MCPServerSpec,
        format: ConfigurationFormat,
        at url: URL,
        afterWrite: @escaping () -> Void,
    ) throws -> InstallWorkflowResult {
        try installServer(server, format: format, at: url, hooks: .init(
            verificationOverride: nil,
            afterWrite: afterWrite,
            removeItem: { try FileManager.default.removeItem(at: $0) }
        ))
    }

    private static func installServer(
        _ server: MCPServerSpec,
        format: ConfigurationFormat,
        at url: URL,
        hooks: InstallHooks
    ) throws -> InstallWorkflowResult {
        do {
            try server.validate()
        } catch let error as MCPServerSpec.ValidationError {
            throw InstallWorkflowError.invalidServer(error)
        }
        return try withConfigurationLock(at: url) {
            try installServerLocked(
                server,
                format: format,
                at: url,
                hooks: hooks
            )
        }
    }

    private static func installServerLocked(
        _ server: MCPServerSpec,
        format: ConfigurationFormat,
        at url: URL,
        hooks: InstallHooks
    ) throws -> InstallWorkflowResult {
        let prepared = try prepareServerUpdate(server, format: format, at: url)
        let existed = prepared.sourceIdentity.fileExisted
        hooks.afterPrepare?()
        do {
            try writeConfig(
                prepared.data,
                to: url,
                backupSuffix: server.backupSuffix,
                beforeReplacing: { try requireUnchanged(prepared.sourceIdentity, at: url) }
            )
        } catch let error as ConfigWriteError {
            throw try workflowError(for: error, server: server, url: url, configurationExisted: existed)
        } catch let error as InstallWorkflowError {
            throw error
        } catch {
            throw InstallWorkflowError.writeFailed(url: url, detail: error.localizedDescription)
        }

        hooks.afterWrite?()
        let committedIdentity = try configurationIdentity(at: url)
        let backupURL = existed ? try sibling(of: url, suffix: server.backupSuffix) : nil
        // Sampling the live path is not enough to claim the file as ours: a
        // replacement landing between the commit and this read would be taken
        // for the installed configuration, and a rollback would then displace
        // and delete another writer's file.
        guard committedIdentity.contents == prepared.data else {
            throw InstallWorkflowError.verificationTargetChanged(url: url, backupURL: backupURL)
        }
        let verified: Bool = if let verificationOverride = hooks.verificationOverride {
            verificationOverride()
        } else {
            verifyServer(server, format: format, at: url)
        }
        do {
            try requireUnchanged(committedIdentity, at: url)
        } catch {
            throw InstallWorkflowError.verificationTargetChanged(url: url, backupURL: backupURL)
        }
        guard verified else {
            try rollbackAfterFailedVerification(
                server: server,
                format: format,
                url: url,
                backupURL: backupURL,
                hooks: hooks
            )
        }
        return InstallWorkflowResult(alreadyPresent: prepared.alreadyPresent, backupURL: backupURL)
    }

    private static func rollbackAfterFailedVerification(
        server: MCPServerSpec,
        format: ConfigurationFormat,
        url: URL,
        backupURL: URL?,
        hooks: InstallHooks
    ) throws -> Never {
        if backupURL != nil {
            let restored: RestoreWorkflowResult
            do {
                restored = try restoreBackup(
                    for: server,
                    format: format,
                    at: url,
                    displacedSuffix: ".verification-failed-\(UUID().uuidString)",
                    moveItem: { try FileManager.default.moveItem(at: $0, to: $1) }
                )
            } catch let error as InstallWorkflowError {
                // A committed restore already names where each file ended up,
                // which a rollback failure would discard.
                if case .restorationCommitted = error { throw error }
                throw InstallWorkflowError.verificationRollbackFailed(
                    url: url, backupURL: backupURL, detail: String(describing: error)
                )
            } catch {
                throw InstallWorkflowError.verificationRollbackFailed(
                    url: url, backupURL: backupURL, detail: error.localizedDescription
                )
            }
            if let displacedURL = restored.displacedURL {
                do {
                    try hooks.removeItem(displacedURL)
                } catch {
                    throw InstallWorkflowError.verificationRollbackCleanupFailed(
                        url: url,
                        displacedURL: displacedURL,
                        detail: error.localizedDescription
                    )
                }
            }
        } else {
            do {
                try hooks.removeItem(url)
            } catch {
                throw InstallWorkflowError.verificationRollbackFailed(
                    url: url, backupURL: nil, detail: error.localizedDescription
                )
            }
        }
        throw InstallWorkflowError.verificationFailed(url: url, backupURL: nil)
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

    static func validateBackup(at url: URL, format: ConfigurationFormat) throws {
        do {
            switch format {
            case .json:
                _ = try existingJSON(at: url)
            case .codexTOML:
                try validateCodexTOML(try existingTOML(at: url))
            }
        } catch let ConfigurationReadError.tooLarge(limit) {
            throw InstallWorkflowError.configurationTooLarge(url: url, limit: limit)
        } catch let ConfigurationReadError.unsafePath(kind) {
            throw InstallWorkflowError.unsafePath(url: url, kind: kind)
        } catch {
            throw InstallWorkflowError.invalidBackup(url: url, detail: error.localizedDescription)
        }
    }

    static func sibling(of url: URL, suffix: String) throws -> URL {
        guard isSafeFilenameSuffix(suffix) else {
            throw InstallWorkflowError.unsafeSiblingSuffix(suffix)
        }
        let directory = url.deletingLastPathComponent().standardizedFileURL
        let candidate = directory
            .appendingPathComponent(url.lastPathComponent + suffix)
            .standardizedFileURL
        guard candidate.deletingLastPathComponent() == directory else {
            throw InstallWorkflowError.unsafeSiblingSuffix(suffix)
        }
        return candidate
    }
}

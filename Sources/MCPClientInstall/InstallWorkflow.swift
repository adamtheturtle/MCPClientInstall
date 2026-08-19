import Foundation
import MCPClientInstallSystem

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private struct InstallHooks {
    let verificationOverride: (() -> Bool)?
    let afterPrepare: (() -> Void)?
    let removeItem: (URL) throws -> Void
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
        case verificationFailed(url: URL, backupURL: URL?)
        case verificationTargetChanged(url: URL, backupURL: URL?)
        case verificationRollbackFailed(url: URL, backupURL: URL?, detail: String)
        case verificationRollbackCleanupFailed(url: URL, displacedURL: URL, detail: String)
        case backupUnavailable(url: URL)
        case invalidBackup(url: URL, detail: String)
        case displacedFileExists(url: URL)
        case unsafeSiblingSuffix(String)
        case restorationFailed(url: URL, detail: String)
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
                exchangeItem: atomicExchange,
                afterExchange: {},
                syncFile: syncConfigurationFile,
                syncDirectory: syncConfigurationDirectory,
                moveItem: { try FileManager.default.moveItem(at: $0, to: $1) }
            )
        }
    }
}

extension MCPClientInstall {
    static func restoreBackup(
        for server: MCPServerSpec,
        format: ConfigurationFormat,
        at url: URL,
        displacedSuffix: String,
        exchangeItem: (URL, URL) throws -> Void = atomicExchange,
        afterExchange: () throws -> Void = {},
        syncFile: (URL) throws -> Void = syncConfigurationFile,
        syncDirectory: (URL) throws -> Void = syncConfigurationDirectory,
        moveItem: (URL, URL) throws -> Void,
    ) throws -> RestoreWorkflowResult {
        do {
            try server.validateBackupPolicy()
        } catch let error as MCPServerSpec.ValidationError {
            throw InstallWorkflowError.invalidServer(error)
        }
        let backupURL = try sibling(of: url, suffix: server.backupSuffix)
        try requireRegularBackup(at: backupURL)
        try validateBackup(at: backupURL, format: format)

        let currentKind = configPathKind(at: url)
        guard currentKind == .absent || currentKind == .regularFile else {
            throw InstallWorkflowError.unsafePath(url: url, kind: currentKind)
        }
        guard currentKind == .regularFile else {
            do {
                try syncFile(backupURL)
                try moveItem(backupURL, url)
                try syncFile(url)
                try syncDirectory(url.deletingLastPathComponent())
                return RestoreWorkflowResult(displacedURL: nil)
            } catch {
                throw InstallWorkflowError.restorationFailed(url: url, detail: error.localizedDescription)
            }
        }

        let displacedURL = try sibling(of: url, suffix: displacedSuffix)
        guard configPathKind(at: displacedURL) == .absent else {
            throw InstallWorkflowError.displacedFileExists(url: displacedURL)
        }
        do {
            try syncFile(backupURL)
            try exchangeItem(url, backupURL)
            try syncFile(url)
            try syncDirectory(url.deletingLastPathComponent())
            try afterExchange()
            try moveItem(backupURL, displacedURL)
            try syncFile(displacedURL)
            try syncDirectory(url.deletingLastPathComponent())
            return RestoreWorkflowResult(displacedURL: displacedURL)
        } catch {
            throw InstallWorkflowError.restorationFailed(url: url, detail: error.localizedDescription)
        }
    }

    private static func requireRegularBackup(at backupURL: URL) throws {
        let kind = configPathKind(at: backupURL)
        if kind == .absent {
            throw InstallWorkflowError.backupUnavailable(url: backupURL)
        }
        guard kind == .regularFile else {
            throw InstallWorkflowError.unsafePath(url: backupURL, kind: kind)
        }
    }

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
            afterPrepare: nil,
            removeItem: removeItem
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
        } catch let error as InstallWorkflowError {
            throw error
        } catch let ConfigWriteError.unsafePath(kind) {
            throw InstallWorkflowError.unsafePath(url: url, kind: kind)
        } catch {
            throw InstallWorkflowError.writeFailed(url: url, detail: error.localizedDescription)
        }

        let committedIdentity = try configurationIdentity(at: url)
        let backupURL = existed ? try sibling(of: url, suffix: server.backupSuffix) : nil
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

    private static func validateBackup(at url: URL, format: ConfigurationFormat) throws {
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

    private static func sibling(of url: URL, suffix: String) throws -> URL {
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

private func atomicExchange(_ first: URL, _ second: URL) throws {
    let result = first.path.withCString { firstPath in
        second.path.withCString { secondPath in
            mcp_atomic_exchange(firstPath, secondPath)
        }
    }
    guard result == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

private func syncConfigurationFile(at url: URL) throws {
    let descriptor = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC) }
    guard descriptor >= 0 else { throw currentPOSIXError() }
    defer { _ = close(descriptor) }
    guard fsync(descriptor) == 0 else { throw currentPOSIXError() }
}

private func syncConfigurationDirectory(at url: URL) throws {
    let descriptor = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC) }
    guard descriptor >= 0 else { throw currentPOSIXError() }
    defer { _ = close(descriptor) }
    guard fsync(descriptor) == 0 else { throw currentPOSIXError() }
}

private func currentPOSIXError() -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
}

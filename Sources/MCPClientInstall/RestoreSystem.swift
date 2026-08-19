import Foundation
import MCPClientInstallSystem

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct RestoreHooks {
    let exchangeItem: (URL, URL) throws -> Void
    let beforeExchange: () throws -> Void
    let afterExchange: () throws -> Void
    let syncFile: (URL) throws -> Void
    let syncDirectory: (URL) throws -> Void
    let moveItem: (URL, URL) throws -> Void

    init(
        exchangeItem: @escaping (URL, URL) throws -> Void = atomicExchange,
        beforeExchange: @escaping () throws -> Void = {},
        afterExchange: @escaping () throws -> Void = {},
        syncFile: @escaping (URL) throws -> Void = syncConfigurationFile,
        syncDirectory: @escaping (URL) throws -> Void = syncConfigurationDirectory,
        moveItem: @escaping (URL, URL) throws -> Void
    ) {
        self.exchangeItem = exchangeItem
        self.beforeExchange = beforeExchange
        self.afterExchange = afterExchange
        self.syncFile = syncFile
        self.syncDirectory = syncDirectory
        self.moveItem = moveItem
    }
}

struct ExistingRestoreState {
    let format: MCPClientInstall.ConfigurationFormat
    let url: URL
    let backupURL: URL
    let backupIdentity: MCPClientInstall.ConfigurationIdentity
    let displacedURL: URL
}

extension MCPClientInstall {
    static func restoreOverExistingConfiguration(
        state: ExistingRestoreState,
        hooks: RestoreHooks
    ) throws -> RestoreWorkflowResult {
        let format = state.format
        let url = state.url
        let backupURL = state.backupURL
        let backupIdentity = state.backupIdentity
        let displacedURL = state.displacedURL
        let currentIdentity = try configurationIdentity(at: url)
        do {
            try hooks.syncFile(backupURL)
            try hooks.beforeExchange()
            try requireUnchanged(backupIdentity, at: backupURL)
            try hooks.exchangeItem(url, backupURL)
            let displacedMatches = (try? configurationIdentity(at: backupURL)) == currentIdentity
            guard displacedMatches else {
                try hooks.exchangeItem(url, backupURL)
                try hooks.syncDirectory(url.deletingLastPathComponent())
                throw InstallWorkflowError.configurationChanged(url: url)
            }
            guard try configurationIdentity(at: url) == backupIdentity else {
                try hooks.exchangeItem(url, backupURL)
                try hooks.syncDirectory(url.deletingLastPathComponent())
                throw InstallWorkflowError.configurationChanged(url: backupURL)
            }
            do {
                try validateBackup(at: url, format: format)
            } catch {
                try hooks.exchangeItem(url, backupURL)
                try hooks.syncDirectory(url.deletingLastPathComponent())
                throw error
            }
            try commitRestore(state: state, hooks: hooks)
            return RestoreWorkflowResult(displacedURL: displacedURL)
        } catch let error as InstallWorkflowError {
            throw error
        } catch {
            throw InstallWorkflowError.restorationFailed(url: url, detail: error.localizedDescription)
        }
    }

    /// Finishes a restore whose exchange has already taken effect.
    ///
    /// The backup is live at the configuration path from here on, so a
    /// durability or cleanup failure is not a failed restore. Reporting one as
    /// `restorationFailed` invites a retry, which would find the previous file
    /// still at the backup path, accept it as the backup, and swap the restored
    /// configuration back out again.
    private static func commitRestore(
        state: ExistingRestoreState,
        hooks: RestoreHooks
    ) throws {
        let directory = state.url.deletingLastPathComponent()
        var displacedURL = state.backupURL
        do {
            try hooks.syncFile(state.url)
            try hooks.syncDirectory(directory)
            try hooks.afterExchange()
            try hooks.moveItem(state.backupURL, state.displacedURL)
            displacedURL = state.displacedURL
            try hooks.syncFile(state.displacedURL)
            try hooks.syncDirectory(directory)
        } catch {
            throw InstallWorkflowError.restorationCommitted(
                url: state.url,
                displacedURL: displacedURL,
                detail: error.localizedDescription
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
        moveItem: @escaping (URL, URL) throws -> Void
    ) throws -> RestoreWorkflowResult {
        try restoreBackup(
            for: server,
            format: format,
            at: url,
            displacedSuffix: displacedSuffix,
            hooks: .init(moveItem: moveItem)
        )
    }

    static func restoreBackup(
        for server: MCPServerSpec,
        format: ConfigurationFormat,
        at url: URL,
        displacedSuffix: String,
        hooks: RestoreHooks
    ) throws -> RestoreWorkflowResult {
        do {
            try server.validateBackupPolicy()
        } catch let error as MCPServerSpec.ValidationError {
            throw InstallWorkflowError.invalidServer(error)
        }
        let backupURL = try sibling(of: url, suffix: server.backupSuffix)
        try requireRegularBackup(at: backupURL)
        let backupIdentity = try configurationIdentity(at: backupURL)
        try validateBackup(at: backupURL, format: format)
        try requireUnchanged(backupIdentity, at: backupURL)

        let currentKind = configPathKind(at: url)
        guard currentKind == .absent || currentKind == .regularFile else {
            throw InstallWorkflowError.unsafePath(url: url, kind: currentKind)
        }
        guard currentKind == .regularFile else {
            do {
                try hooks.syncFile(backupURL)
                try hooks.moveItem(backupURL, url)
                try hooks.syncFile(url)
                try hooks.syncDirectory(url.deletingLastPathComponent())
                return RestoreWorkflowResult(displacedURL: nil)
            } catch {
                throw InstallWorkflowError.restorationFailed(url: url, detail: error.localizedDescription)
            }
        }

        let displacedURL = try sibling(of: url, suffix: displacedSuffix)
        guard configPathKind(at: displacedURL) == .absent else {
            throw InstallWorkflowError.displacedFileExists(url: displacedURL)
        }
        return try restoreOverExistingConfiguration(
            state: .init(
                format: format,
                url: url,
                backupURL: backupURL,
                backupIdentity: backupIdentity,
                displacedURL: displacedURL
            ),
            hooks: hooks
        )
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
}

func atomicExchange(_ first: URL, _ second: URL) throws {
    let result = first.path.withCString { firstPath in
        second.path.withCString { secondPath in
            mcp_atomic_exchange(firstPath, secondPath)
        }
    }
    guard result == 0 else { throw currentPOSIXError() }
}

func syncConfigurationFile(at url: URL) throws {
    try syncDescriptor(forPathAt: url)
}

func syncConfigurationDirectory(at url: URL) throws {
    try syncDescriptor(forPathAt: url)
}

private func syncDescriptor(forPathAt url: URL) throws {
    let descriptor = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC) }
    guard descriptor >= 0 else { throw currentPOSIXError() }
    defer { _ = close(descriptor) }
    try flushToDevice(descriptor)
}

/// Flushes a descriptor all the way to the storage device.
///
/// Apple's `fsync` only hands the data to the drive, which can still lose it to
/// a crash or power cut, so `F_FULLFSYNC` is the durable barrier there. Some
/// file systems do not implement it and report `ENOTSUP` or `EINVAL`; `fsync`
/// is the best available guarantee on those.
private func flushToDevice(_ descriptor: Int32) throws {
#if canImport(Darwin)
    if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
    let code = errno
    guard code == ENOTSUP || code == EINVAL else { throw currentPOSIXError() }
#endif
    guard fsync(descriptor) == 0 else { throw currentPOSIXError() }
}

private func currentPOSIXError() -> NSError {
    .init(domain: NSPOSIXErrorDomain, code: Int(errno))
}

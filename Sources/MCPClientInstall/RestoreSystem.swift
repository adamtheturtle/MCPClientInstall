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
            try hooks.syncFile(url)
            try hooks.syncDirectory(url.deletingLastPathComponent())
            try hooks.afterExchange()
            try hooks.moveItem(backupURL, displacedURL)
            try hooks.syncFile(displacedURL)
            try hooks.syncDirectory(url.deletingLastPathComponent())
            return RestoreWorkflowResult(displacedURL: displacedURL)
        } catch let error as InstallWorkflowError {
            throw error
        } catch {
            throw InstallWorkflowError.restorationFailed(url: url, detail: error.localizedDescription)
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
    let descriptor = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC) }
    guard descriptor >= 0 else { throw currentPOSIXError() }
    defer { _ = close(descriptor) }
    guard fsync(descriptor) == 0 else { throw currentPOSIXError() }
}

func syncConfigurationDirectory(at url: URL) throws {
    let descriptor = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC) }
    guard descriptor >= 0 else { throw currentPOSIXError() }
    defer { _ = close(descriptor) }
    guard fsync(descriptor) == 0 else { throw currentPOSIXError() }
}

private func currentPOSIXError() -> NSError {
    .init(domain: NSPOSIXErrorDomain, code: Int(errno))
}

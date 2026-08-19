#if !os(Linux)
import Darwin
import Foundation

extension MCPClientInstall {
    static func replaceConfigOnDarwin(
        in directory: BoundConfigurationDirectory,
        prepared: PreparedTemporary,
        backupSuffix: String,
        targetIdentity: ConfigurationIdentity,
        hooks: ConfigWriteHooks
    ) throws {
        let url = directory.operationalURL
        do {
            try hooks.beforeReplacing()
            try requireUnchanged(targetIdentity, at: url)
            try hooks.afterCheckingTarget()
            try directory.requireStillNamed()
            _ = try FileManager.default.replaceItemAt(
                url,
                withItemAt: prepared.url,
                backupItemName: url.lastPathComponent + backupSuffix,
                options: [.withoutDeletingBackupItem]
            )
            try requireBoundTemporary(prepared, at: url, contains: prepared.data)
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent(url.lastPathComponent + backupSuffix)
            guard try configurationIdentity(at: backup) == targetIdentity else {
                // The backup holds the file another writer put at the live path
                // and the live path holds the replacement this install refuses.
                // One rename restores the concurrent file and unlinks the
                // refusal together, so no half-undone state can leave a refused
                // replacement at the backup path for a later restore to revive.
                try moveItem(at: backup, replacing: url)
                try syncConfigurationDirectory(at: url.deletingLastPathComponent())
                throw InstallWorkflowError.configurationChanged(url: directory.displayURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: prepared.url)
            throw error
        }
    }

    /// Moves `source` onto `destination`, replacing and unlinking whatever is
    /// there, in one operation.
    ///
    /// `FileManager.moveItem` refuses an existing destination, which would
    /// leave the caller undoing a replacement in two steps that can fail
    /// between them.
    private static func moveItem(at source: URL, replacing destination: URL) throws {
        let result = source.path.withCString { from in
            destination.path.withCString { to in rename(from, to) }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
#endif

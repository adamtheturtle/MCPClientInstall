#if !os(Linux)
import Foundation

extension MCPClientInstall {
    static func replaceConfigOnDarwin(
        prepared: PreparedTemporary,
        at url: URL,
        backupSuffix: String,
        targetIdentity: ConfigurationIdentity,
        hooks: ConfigWriteHooks
    ) throws {
        do {
            try hooks.beforeReplacing()
            try requireUnchanged(targetIdentity, at: url)
            try hooks.afterCheckingTarget()
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
                try atomicExchange(url, backup)
                try syncConfigurationDirectory(at: url.deletingLastPathComponent())
                throw InstallWorkflowError.configurationChanged(url: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: prepared.url)
            throw error
        }
    }
}
#endif

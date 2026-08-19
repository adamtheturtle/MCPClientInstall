#if !os(Linux)
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
                try atomicExchange(url, backup)
                try syncConfigurationDirectory(at: url.deletingLastPathComponent())
                throw InstallWorkflowError.configurationChanged(url: directory.displayURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: prepared.url)
            throw error
        }
    }
}
#endif

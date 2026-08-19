import Foundation

extension MCPClientInstall {
    static func workflowError(
        for error: ConfigWriteError,
        server: MCPServerSpec,
        url: URL,
        configurationExisted: Bool
    ) throws -> InstallWorkflowError {
        switch error {
        case let .unsafePath(kind):
            return .unsafePath(url: url, kind: kind)
        case let .configurationTooLarge(limit):
            return .configurationTooLarge(url: url, limit: limit)
        case .unsafeBackupSuffix:
            return .writeFailed(url: url, detail: error.localizedDescription)
        case let .committed(detail):
            let backupURL = configurationExisted
                ? try sibling(of: url, suffix: server.backupSuffix)
                : nil
            return .writeCommitted(url: url, backupURL: backupURL, detail: detail)
        }
    }
}

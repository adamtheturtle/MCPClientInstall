import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension MCPClientInstall {
    enum ConfigurationIdentity: Equatable, Sendable {
        case absent
        case regular(device: UInt64, inode: UInt64, size: UInt64, modified: Date)
    }

    static func withConfigurationLock<Result>(
        at configURL: URL,
        _ operation: () throws -> Result
    ) throws -> Result {
        let lockURL = configURL.deletingLastPathComponent()
            .appendingPathComponent(".\(configURL.lastPathComponent).mcp-client-install.lock")
        let descriptor = lockURL.path.withCString {
            open($0, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw InstallWorkflowError.lockFailed(
                url: lockURL,
                detail: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)).localizedDescription
            )
        }
        defer { _ = close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw InstallWorkflowError.lockFailed(
                url: lockURL,
                detail: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)).localizedDescription
            )
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    static func configurationIdentity(at url: URL) throws -> ConfigurationIdentity {
        let kind = configPathKind(at: url)
        switch kind {
        case .absent:
            return .absent
        case .regularFile:
            return try regularConfigurationIdentity(at: url)
        case .symbolicLink, .special, .unavailable:
            throw InstallWorkflowError.unsafePath(url: url, kind: kind)
        }
    }

    private static func regularConfigurationIdentity(at url: URL) throws -> ConfigurationIdentity {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
                  let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let modified = attributes[.modificationDate] as? Date
            else {
                throw InstallWorkflowError.readFailed(
                    url: url, detail: "The file identity metadata is incomplete."
                )
            }
            return .regular(device: device, inode: inode, size: size, modified: modified)
        } catch let error as InstallWorkflowError {
            throw error
        } catch {
            throw InstallWorkflowError.readFailed(url: url, detail: error.localizedDescription)
        }
    }

    static func requireUnchanged(_ expected: ConfigurationIdentity, at url: URL) throws {
        guard try configurationIdentity(at: url) == expected else {
            throw InstallWorkflowError.configurationChanged(url: url)
        }
    }
}

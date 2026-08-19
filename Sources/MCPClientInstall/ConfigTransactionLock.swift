import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension MCPClientInstall {
    enum ConfigurationIdentity: Equatable, Sendable {
        case absent
        case regular(
            device: UInt64,
            inode: UInt64,
            size: UInt64,
            modified: Date,
            contents: Data
        )

        var fileExisted: Bool {
            if case .regular = self { return true }
            return false
        }

        /// The bytes this identity was taken from, or nil when nothing was there.
        var contents: Data? {
            if case let .regular(_, _, _, _, contents) = self { return contents }
            return nil
        }
    }

    /// Serializes configuration transactions on the directory holding the file.
    ///
    /// The lock is an exclusive `flock` on a descriptor for the configuration's
    /// own directory. Nothing is created, so a rejected install leaves no trace
    /// beside the configuration, and there is no shared lock directory another
    /// local user could pre-create, hold, or unlink out from under a waiter.
    ///
    /// Locking the directory the configuration lives in also keeps one identity
    /// per configuration: every process reaches the same inode no matter how the
    /// path is spelled, what `TMPDIR` says, or whether the host is sandboxed.
    /// Configurations sharing a directory therefore serialize against each
    /// other, which is stricter than necessary but never wrong.
    static func withConfigurationLock<Result>(
        at configURL: URL,
        _ operation: () throws -> Result
    ) throws -> Result {
        let directory = configURL.deletingLastPathComponent()
        let descriptor = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw lockFailure(at: directory) }
        defer { _ = close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw lockFailure(at: directory) }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private static func lockFailure(at url: URL) -> InstallWorkflowError {
        .lockFailed(
            url: url,
            detail: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)).localizedDescription
        )
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
            if let linkCount = (attributes[.referenceCount] as? NSNumber)?.uint64Value,
               linkCount > 1 {
                throw InstallWorkflowError.multiplyLinkedConfiguration(
                    url: url, linkCount: linkCount
                )
            }
            let contents = try boundedConfigurationData(at: url)
            return .regular(
                device: device,
                inode: inode,
                size: size,
                modified: modified,
                contents: contents
            )
        } catch let error as InstallWorkflowError {
            throw error
        } catch let ConfigurationReadError.tooLarge(limit) {
            throw InstallWorkflowError.configurationTooLarge(url: url, limit: limit)
        } catch let ConfigurationReadError.unsafePath(kind) {
            throw InstallWorkflowError.unsafePath(url: url, kind: kind)
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

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
    }

    static func withConfigurationLock<Result>(
        at configURL: URL,
        _ operation: () throws -> Result
    ) throws -> Result {
        let lockDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPClientInstall-locks", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: lockDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw InstallWorkflowError.lockFailed(
                url: lockDirectory, detail: error.localizedDescription
            )
        }
        let lockURL = lockDirectory.appendingPathComponent("\(stableLockKey(for: configURL)).lock")
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

    /// Lock files live in the process-temporary lock directory and intentionally
    /// persist so concurrent and future waiters always open the same inode.
    private static func stableLockKey(for configURL: URL) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in configURL.standardizedFileURL.path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
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

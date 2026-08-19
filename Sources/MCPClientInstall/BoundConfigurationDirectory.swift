import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class BoundConfigurationDirectory {
    let displayURL: URL
    let operationalURL: URL
    private let descriptor: Int32
    private let device: UInt64
    private let inode: UInt64
    private let displayDirectoryPath: String

    init(containing displayURL: URL) throws {
        self.displayURL = displayURL
        let directory = displayURL.deletingLastPathComponent()
        displayDirectoryPath = directory.path.trimmingTrailingPathSeparators()
        descriptor = displayDirectoryPath.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw MCPClientInstall.InstallWorkflowError.unsafePath(
                url: directory,
                kind: MCPClientInstall.configPathKind(at: directory)
            )
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let code = errno
            _ = close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        device = UInt64(status.st_dev)
        inode = UInt64(status.st_ino)
#if os(Linux)
        let descriptorRoot = "/proc/self/fd/\(descriptor)"
        operationalURL = URL(fileURLWithPath: descriptorRoot, isDirectory: true)
            .appendingPathComponent(displayURL.lastPathComponent)
#else
        operationalURL = displayURL
#endif
    }

    deinit { _ = close(descriptor) }

    func requireStillNamed() throws {
        let currentDescriptor = displayDirectoryPath.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard currentDescriptor >= 0 else {
            throw MCPClientInstall.InstallWorkflowError.configurationChanged(url: displayURL)
        }
        defer { _ = close(currentDescriptor) }
        var status = stat()
        guard fstat(currentDescriptor, &status) == 0,
              UInt64(status.st_dev) == device,
              UInt64(status.st_ino) == inode
        else {
            throw MCPClientInstall.InstallWorkflowError.configurationChanged(url: displayURL)
        }
    }
}

private extension String {
    func trimmingTrailingPathSeparators() -> String {
        var result = self
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

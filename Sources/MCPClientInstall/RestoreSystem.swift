import Foundation
import MCPClientInstallSystem

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

func atomicExchange(_ first: URL, _ second: URL) throws {
    let result = first.path.withCString { firstPath in
        second.path.withCString { secondPath in
            mcp_atomic_exchange(firstPath, secondPath)
        }
    }
    guard result == 0 else { throw currentRestorePOSIXError() }
}

func syncConfigurationFile(at url: URL) throws {
    let descriptor = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC) }
    guard descriptor >= 0 else { throw currentRestorePOSIXError() }
    defer { _ = close(descriptor) }
    guard fsync(descriptor) == 0 else { throw currentRestorePOSIXError() }
}

func syncConfigurationDirectory(at url: URL) throws {
    let descriptor = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC) }
    guard descriptor >= 0 else { throw currentRestorePOSIXError() }
    defer { _ = close(descriptor) }
    guard fsync(descriptor) == 0 else { throw currentRestorePOSIXError() }
}

private func currentRestorePOSIXError() -> NSError {
    .init(domain: NSPOSIXErrorDomain, code: Int(errno))
}

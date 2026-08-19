import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct PreparedTemporary {
    let url: URL
    let descriptor: Int32
    let data: Data
}

struct ConfigWriteHooks {
    let beforeReplacing: () throws -> Void
    let afterCommit: () throws -> Void
    let afterWritingTemporary: (URL) throws -> Void
    let afterCheckingTarget: () throws -> Void

    init(
        beforeReplacing: @escaping () throws -> Void,
        afterCommit: @escaping () throws -> Void = {},
        afterWritingTemporary: @escaping (URL) throws -> Void = { _ in },
        afterCheckingTarget: @escaping () throws -> Void = {}
    ) {
        self.beforeReplacing = beforeReplacing
        self.afterCommit = afterCommit
        self.afterWritingTemporary = afterWritingTemporary
        self.afterCheckingTarget = afterCheckingTarget
    }
}

func writeAbsentConfig(
    _ data: Data,
    in directory: BoundConfigurationDirectory,
    identity: MCPClientInstall.ConfigurationIdentity,
    hooks: ConfigWriteHooks
) throws {
    let url = directory.operationalURL
    let temporary = url.deletingLastPathComponent()
        .appendingPathComponent(".mcp-client-install-\(UUID().uuidString).tmp")
    do {
        let prepared = try preparePrivateTemporary(data, at: temporary)
        defer { _ = close(prepared.descriptor) }
        try hooks.afterWritingTemporary(temporary)
        try requireBoundTemporary(prepared, contains: data)
        try hooks.beforeReplacing()
        try MCPClientInstall.requireUnchanged(identity, at: url)
        try hooks.afterCheckingTarget()
        try directory.requireStillNamed()
        try FileManager.default.moveItem(at: temporary, to: url)
        try requireBoundTemporary(prepared, at: url, contains: data)
    } catch {
        try? FileManager.default.removeItem(at: temporary)
        throw error
    }
}

func preparePrivateTemporary(_ data: Data, at url: URL) throws -> PreparedTemporary {
    let descriptor = url.path.withCString {
        open($0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
    }
    guard descriptor >= 0 else { throw temporaryPOSIXError() }
    let privateMode = mode_t(0o600)
    guard fchmod(descriptor, privateMode) == 0 else {
        return try failTemporary(descriptor, at: url, code: errno)
    }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & mode_t(0o777) == privateMode else {
        return try failTemporary(descriptor, at: url, code: errno == 0 ? EACCES : errno)
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    do {
        try handle.write(contentsOf: data)
        try handle.synchronize()
        return PreparedTemporary(url: url, descriptor: descriptor, data: data)
    } catch {
        _ = close(descriptor)
        try? FileManager.default.removeItem(at: url)
        throw error
    }
}

func requireBoundTemporary(
    _ temporary: PreparedTemporary,
    at path: URL? = nil,
    contains expectedData: Data
) throws {
    var descriptorStatus = stat()
    guard fstat(temporary.descriptor, &descriptorStatus) == 0 else {
        throw temporaryPOSIXError()
    }
    let inspectedPath = path ?? temporary.url
    var pathStatus = stat()
    let statusResult = inspectedPath.path.withCString { lstat($0, &pathStatus) }
    guard statusResult == 0,
          descriptorStatus.st_dev == pathStatus.st_dev,
          descriptorStatus.st_ino == pathStatus.st_ino,
          descriptorStatus.st_nlink == 1,
          pathStatus.st_nlink == 1,
          descriptorStatus.st_size == off_t(expectedData.count)
    else {
        throw MCPClientInstall.InstallWorkflowError.configurationChanged(url: inspectedPath)
    }
    let duplicate = dup(temporary.descriptor)
    guard duplicate >= 0 else { throw temporaryPOSIXError() }
    let handle = FileHandle(fileDescriptor: duplicate, closeOnDealloc: true)
    try handle.seek(toOffset: 0)
    guard try handle.readToEnd() == expectedData else {
        throw MCPClientInstall.InstallWorkflowError.configurationChanged(url: inspectedPath)
    }
}

private func failTemporary(
    _ descriptor: Int32,
    at url: URL,
    code: Int32
) throws -> PreparedTemporary {
    _ = close(descriptor)
    try? FileManager.default.removeItem(at: url)
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
}

private func temporaryPOSIXError() -> NSError {
    .init(domain: NSPOSIXErrorDomain, code: Int(errno))
}

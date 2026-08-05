#if os(Linux)
import Foundation
import Glibc
import Testing

@testable import MCPClientInstall

@_silgen_name("setxattr")
private func linuxSetXattr(
    _ path: UnsafePointer<CChar>,
    _ name: UnsafePointer<CChar>,
    _ value: UnsafeRawPointer?,
    _ size: Int,
    _ flags: Int32
) -> Int32

@_silgen_name("getxattr")
private func linuxGetXattr(
    _ path: UnsafePointer<CChar>,
    _ name: UnsafePointer<CChar>,
    _ value: UnsafeMutableRawPointer?,
    _ size: Int
) -> Int

@Suite("Linux replacement metadata")
struct LinuxMetadataTests {
    @Test func preservesPermissionsAndExposesExtendedAttributeLoss() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("config.json")
        try Data("old".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640], ofItemAtPath: file.path
        )
        try setExtendedAttribute(Data("metadata".utf8), at: file)

        try MCPClientInstall.writeConfig(
            Data("new".utf8), to: file, backupSuffix: ".backup"
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        let extendedAttributeSize = extendedAttributeSize(at: file)
        let extendedAttributeError = errno
        #expect(permissions.intValue & 0o777 == 0o640)
        #expect(extendedAttributeSize == -1)
        #expect(extendedAttributeError == ENODATA)
    }

    private func setExtendedAttribute(_ value: Data, at url: URL) throws {
        let result = url.path.withCString { path in
            "user.mcpclientinstall-test".withCString { name in
                value.withUnsafeBytes { bytes in
                    linuxSetXattr(path, name, bytes.baseAddress, bytes.count, 0)
                }
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func extendedAttributeSize(at url: URL) -> Int {
        url.path.withCString { path in
            "user.mcpclientinstall-test".withCString { name in
                linuxGetXattr(path, name, nil, 0)
            }
        }
    }
}
#endif

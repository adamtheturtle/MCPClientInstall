//
//  ConfigWrite.swift
//  MCPClientInstall
//
//  How the installer replaces a client's configuration file: validating the
//  command it is about to write, refusing symlinks and special files, preserving
//  metadata, and leaving a recoverable backup.
//

import Foundation

public enum MCPClientInstall {
    /// Whether `path` is something the client can actually execute: present, a
    /// regular file (not a directory or a dangling symlink), and executable.
    public static func isRunnableExecutable(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }

        var isDirectory: ObjCBool = false
        let manager = FileManager.default
        guard manager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }

        return manager.isExecutableFile(atPath: path)
    }

    /// What is sitting at a config path, so the installer can refuse anything it
    /// shouldn't read or replace.
    public enum ConfigPathKind: Equatable, Sendable {
        /// Nothing there yet — the installer will create it.
        case absent
        /// A plain file, the only thing safe to rewrite.
        case regularFile
        /// A symlink. Following it would write somewhere other than the folder the
        /// user granted access to and the UI named.
        case symbolicLink(destination: String)
        /// A directory, FIFO, socket, or device. Reading or replacing one of these
        /// produces confusing or destructive behaviour, and a FIFO can block the UI
        /// outright.
        case special
    }

    /// Classifies the config path without following symlinks.
    public static func configPathKind(at url: URL) -> ConfigPathKind {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: url.path) else { return .absent }
        guard let type = attributes[.type] as? FileAttributeType else { return .special }

        switch type {
        case .typeRegular:
            return .regularFile

        case .typeSymbolicLink:
            let destination = (try? manager.destinationOfSymbolicLink(atPath: url.path)) ?? ""
            return .symbolicLink(destination: destination)

        default:
            return .special
        }
    }

    /// The reason the installer won't touch this path, or nil when it is safe.
    ///
    /// `attributesOfItem` does not follow symlinks, so a link is seen as a link
    /// rather than as whatever it points at.
    public static func refusalReason(for kind: ConfigPathKind, fileName: String) -> String? {
        switch kind {
        case .absent, .regularFile:
            nil

        case let .symbolicLink(destination):
            """
            \(fileName) is a link to \(destination.isEmpty ? "another location" : destination). \
            The installer won't write through it, because that would change a file outside the \
            folder you picked. Edit that file directly, or replace the link with a real config file.
            """

        case .special:
            """
            \(fileName) isn't a regular file, so it can't be read or replaced. \
            Check what's at that path and try again.
            """
        }
    }

    /// Replaces a client's config file, keeping its metadata and leaving a copy of
    /// what was there under `backupSuffix`.
    ///
    /// A plain atomic write creates a fresh file and renames it over the target,
    /// which silently drops the original's POSIX mode, ACLs, and extended
    /// attributes — so updating a deliberately protected config could weaken or
    /// break its access setup. `replaceItemAt` carries that metadata onto the
    /// replacement instead, and its `backupItemName` leaves the previous contents
    /// beside the file so a rewrite defect or an interrupted write is recoverable
    /// rather than final.
    ///
    /// A file that doesn't exist yet has no metadata to keep and nothing to back
    /// up, so it takes the plain write.
    public static func writeConfig(_ data: Data, to url: URL, backupSuffix: String) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else {
            try data.write(to: url, options: .atomic)
            return
        }

        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".mcp-client-install-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
#if os(Linux)
        try replaceConfigOnLinux(at: url, with: temporary, backupSuffix: backupSuffix)
#else
        do {
            _ = try manager.replaceItemAt(
                url,
                withItemAt: temporary,
                backupItemName: url.lastPathComponent + backupSuffix,
                options: [.withoutDeletingBackupItem]
            )
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
#endif
    }

#if os(Linux)
    /// Foundation's `replaceItemAt` is unavailable as a reliable transactional
    /// primitive on Linux. Rename the current file aside, install the prepared
    /// file, and roll both the current and pre-existing backup back on failure.
    private static func replaceConfigOnLinux(
        at url: URL,
        with temporary: URL,
        backupSuffix: String
    ) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        let backup = directory.appendingPathComponent(url.lastPathComponent + backupSuffix)
        let previousBackup = directory
            .appendingPathComponent(".mcp-client-install-\(UUID().uuidString).previous-backup")
        var parkedPreviousBackup = false
        var parkedCurrent = false

        do {
            if manager.fileExists(atPath: backup.path) {
                try manager.moveItem(at: backup, to: previousBackup)
                parkedPreviousBackup = true
            }

            if let permissions = try manager.attributesOfItem(atPath: url.path)[.posixPermissions] {
                try manager.setAttributes([.posixPermissions: permissions], atPath: temporary.path)
            }
            try manager.moveItem(at: url, to: backup)
            parkedCurrent = true
            try manager.moveItem(at: temporary, to: url)

            if parkedPreviousBackup {
                try manager.removeItem(at: previousBackup)
            }
        } catch {
            if manager.fileExists(atPath: temporary.path) {
                try? manager.removeItem(at: temporary)
            }
            if parkedCurrent, !manager.fileExists(atPath: url.path) {
                try? manager.moveItem(at: backup, to: url)
            }
            if parkedPreviousBackup, !manager.fileExists(atPath: backup.path) {
                try? manager.moveItem(at: previousBackup, to: backup)
            }
            throw error
        }
    }
#endif
}

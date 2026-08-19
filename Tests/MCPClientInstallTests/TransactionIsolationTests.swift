import Dispatch
import Foundation
import Testing

@testable import MCPClientInstall

@Suite("Install transaction isolation")
struct TransactionIsolationTests {
    @Test func preparedIdentityCarriesTheRollbackExistenceState() throws {
        let directory = temporaryDirectory()
        let missing = directory.appendingPathComponent("missing.json")
        let existing = directory.appendingPathComponent("existing.json")
        try Data("{}".utf8).write(to: existing)

        #expect(!(try MCPClientInstall.configurationIdentity(at: missing)).fileExisted)
        #expect((try MCPClientInstall.configurationIdentity(at: existing)).fileExisted)
    }

    @Test func concurrentInstallsRetainBothServers() throws {
        let file = temporaryDirectory().appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: file)
        let firstPrepared = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let failures = FailureBox()

        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                _ = try MCPClientInstall.installServer(
                    MCPServerSpec(name: "first", command: "/first"),
                    format: .json,
                    at: file,
                    verificationOverride: nil,
                    afterPrepare: {
                        firstPrepared.signal()
                        releaseFirst.wait()
                    }
                )
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        firstPrepared.wait()

        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            secondStarted.signal()
            defer { secondFinished.signal() }
            do {
                _ = try MCPClientInstall.installServer(
                    MCPServerSpec(name: "second", command: "/second"),
                    format: .json,
                    at: file
                )
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        secondStarted.wait()
        #expect(secondFinished.wait(timeout: .now() + .milliseconds(50)) == .timedOut)
        releaseFirst.signal()
        group.wait()

        #expect(failures.values.isEmpty)
        try expectServers(["first", "second"], at: file)
    }

    @Test func restorationWaitsForTheConfigurationTransactionLock() throws {
        let directory = temporaryDirectory()
        let file = directory.appendingPathComponent("config.json")
        let backup = directory.appendingPathComponent("config.json.backup")
        try Data(#"{"backup":true}"#.utf8).write(to: backup)
        let lockHeld = DispatchSemaphore(value: 0)
        let releaseLock = DispatchSemaphore(value: 0)
        let restoreFinished = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let failures = FailureBox()

        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                try MCPClientInstall.withConfigurationLock(at: file) {
                    lockHeld.signal()
                    releaseLock.wait()
                }
            } catch { failures.append(error.localizedDescription) }
        }
        lockHeld.wait()

        group.enter()
        DispatchQueue.global().async {
            defer { group.leave(); restoreFinished.signal() }
            do {
                _ = try MCPClientInstall.restoreBackup(
                    for: MCPServerSpec(name: "demo", command: "/demo", backupSuffix: ".backup"),
                    format: .json,
                    at: file,
                    displacedSuffix: ".displaced"
                )
            } catch { failures.append(error.localizedDescription) }
        }

        #expect(restoreFinished.wait(timeout: .now() + .milliseconds(50)) == .timedOut)
        releaseLock.signal()
        group.wait()
        #expect(failures.values.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aPathSwapBeforeReplacementIsRejected() throws {
        let directory = temporaryDirectory()
        let file = directory.appendingPathComponent("config.json")
        let parked = directory.appendingPathComponent("parked.json")
        let attacker = directory.appendingPathComponent("attacker.json")
        try Data("{}".utf8).write(to: file)
        try Data(#"{"secret":"unchanged"}"#.utf8).write(to: attacker)

        do {
            _ = try MCPClientInstall.installServer(
                MCPServerSpec(name: "demo", command: "/demo"),
                format: .json,
                at: file,
                verificationOverride: nil,
                afterPrepare: {
                    try? FileManager.default.moveItem(at: file, to: parked)
                    try? FileManager.default.createSymbolicLink(
                        at: file, withDestinationURL: attacker
                    )
                }
            )
            Issue.record("Expected path swap rejection")
        } catch let error as MCPClientInstall.InstallWorkflowError {
            guard case let .unsafePath(unsafeURL, .symbolicLink(destination: _)) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(unsafeURL == file)
        }
        #expect(try String(contentsOf: attacker, encoding: .utf8) == #"{"secret":"unchanged"}"#)
        #expect(try String(contentsOf: parked, encoding: .utf8) == "{}")
    }

    @Test func sameSizeAndModificationDateCannotHideContentChanges() throws {
        let file = temporaryDirectory().appendingPathComponent("config.json")
        try Data(#"{"value":"one"}"#.utf8).write(to: file)
        let identity = try MCPClientInstall.configurationIdentity(at: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let modified = try #require(attributes[.modificationDate] as? Date)

        try Data(#"{"value":"two"}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)

        #expect(throws: MCPClientInstall.InstallWorkflowError.configurationChanged(url: file)) {
            try MCPClientInstall.requireUnchanged(identity, at: file)
        }
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func expectServers(_ names: [String], at file: URL) throws {
        let root = try MCPClientInstall.existingJSON(at: file)
        let servers = try #require(root["mcpServers"] as? [String: Any])
        for name in names { #expect(servers[name] != nil) }
    }
}

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

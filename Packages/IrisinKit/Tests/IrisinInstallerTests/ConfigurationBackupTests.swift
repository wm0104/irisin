import Darwin
import Foundation
import IrisinProtocol
@testable import IrisinInstaller
import XCTest

final class ConfigurationBackupTests: XCTestCase {
    private func fixture(_ body: (URL, ConfigurationBackupEngine) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("var/mobile/Library/Preferences"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("etc/apt/sources.list.d"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = ConfigurationBackupEngine(root: root.path)
        try body(root, engine)
    }

    func testRealSnapshotRestoreReplacesOnlySavedSelectedRoots() throws {
        try fixture { root, engine in
            let preferences = root.appendingPathComponent("var/mobile/Library/Preferences")
            try Data("saved".utf8).write(to: preferences.appendingPathComponent("value"))
            let snapshot = try engine.capture()
            try Data("changed".utf8).write(to: preferences.appendingPathComponent("value"))
            try Data().write(to: preferences.appendingPathComponent("target-only"))
            let untouched = root.appendingPathComponent("var/mobile/Library/ControlCenter")
            try FileManager.default.createDirectory(at: untouched, withIntermediateDirectories: false)
            try Data("untouched".utf8).write(to: untouched.appendingPathComponent("keep"))
            try engine.restore(snapshot, preferences: true, sources: false)
            XCTAssertEqual(try Data(contentsOf: preferences.appendingPathComponent("value")), Data("saved".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: preferences.appendingPathComponent("target-only").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: untouched.appendingPathComponent("keep").path))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.contains("Backup") })
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: preferences.deletingLastPathComponent().path).contains { $0.hasPrefix(".irisin-config-") })
        }
    }

    func testFailureAfterFirstPublishRollsBackEveryTouchedRoot() throws {
        try fixture { root, engine in
            let file = root.appendingPathComponent("var/mobile/Library/Preferences/value")
            try Data("saved".utf8).write(to: file)
            let snapshot = try engine.capture()
            try Data("live".utf8).write(to: file)
            engine.afterPublish = { _ in throw ConfigurationBackupError("injected failure") }
            XCTAssertThrowsError(try engine.restore(snapshot, preferences: true, sources: true))
            XCTAssertEqual(try Data(contentsOf: file), Data("live".utf8))
        }
    }

    func testSameInodeLiveMutationAfterStagingAbortsBeforeAnySwap() throws {
        try fixture { root, engine in
            let file = root.appendingPathComponent("var/mobile/Library/Preferences/value")
            try Data("saved".utf8).write(to: file)
            let snapshot = try engine.capture()
            engine.afterPrepare = {
                let descriptor = open(file.path, O_WRONLY)
                defer { close(descriptor) }
                XCTAssertGreaterThanOrEqual(descriptor, 0)
                _ = Data("newer".utf8).withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
            }
            XCTAssertThrowsError(try engine.restore(snapshot, preferences: true, sources: true))
            XCTAssertEqual(try Data(contentsOf: file), Data("newer".utf8))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().deletingLastPathComponent().path).contains { $0.hasPrefix(".irisin-config-") })
        }
    }

    func testSourcesOnlyDoesNotInspectOrReplaceUnselectedPreferences() throws {
        try fixture { root, engine in
            let file = root.appendingPathComponent("var/mobile/Library/Preferences/value")
            try Data("saved".utf8).write(to: file)
            let snapshot = try engine.capture()
            engine.afterPrepare = { try Data("newer".utf8).write(to: file) }
            try engine.restore(snapshot, preferences: false, sources: true)
            XCTAssertEqual(try Data(contentsOf: file), Data("newer".utf8))
        }
    }

    func testMetadataAndEmptyDirectoriesArePreserved() throws {
        try fixture { root, engine in
            let directory = root.appendingPathComponent("var/mobile/Library/Preferences/empty")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            XCTAssertEqual(chmod(directory.path, 0o750), 0)
            let snapshot = try engine.capture()
            try FileManager.default.removeItem(at: directory)
            try engine.restore(snapshot, preferences: true, sources: false)
            let restored = try engine.capture()
            XCTAssertEqual(snapshot.manifest.metadata["config/Preferences/empty"], restored.manifest.metadata["config/Preferences/empty"])
            XCTAssertEqual(snapshot.manifest.metadata["config/Preferences"], restored.manifest.metadata["config/Preferences"])
        }
    }

    func testRollbackAfterMultiplePublishedRootsRestoresBothOriginals() throws {
        try fixture { root, engine in
            let preference = root.appendingPathComponent("var/mobile/Library/Preferences/value")
            let source = root.appendingPathComponent("etc/apt/sources.list.d/example.sources")
            try Data("saved".utf8).write(to: preference)
            try Data("saved source".utf8).write(to: source)
            let snapshot = try engine.capture()
            try Data("live".utf8).write(to: preference)
            try Data("live source".utf8).write(to: source)
            engine.afterPublish = { path in
                if path == "sources/sources.list.d" { throw ConfigurationBackupError("injected failure") }
            }
            XCTAssertThrowsError(try engine.restore(snapshot, preferences: true, sources: true))
            XCTAssertEqual(try Data(contentsOf: preference), Data("live".utf8))
            XCTAssertEqual(try Data(contentsOf: source), Data("live source".utf8))
        }
    }

    func testCaptureRejectsSymbolicHardAndOversizedFiles() throws {
        try fixture { root, engine in
            let preferences = root.appendingPathComponent("var/mobile/Library/Preferences")
            let file = preferences.appendingPathComponent("value")
            try Data("x".utf8).write(to: file)
            let other = preferences.appendingPathComponent("link")
            XCTAssertEqual(link(file.path, other.path), 0)
            XCTAssertThrowsError(try engine.capture())
            try FileManager.default.removeItem(at: other)
            try FileManager.default.createSymbolicLink(at: other, withDestinationURL: file)
            XCTAssertThrowsError(try engine.capture())
            try FileManager.default.removeItem(at: other)
            let fd = open(file.path, O_WRONLY)
            XCTAssertGreaterThanOrEqual(fd, 0)
            defer { close(fd) }
            XCTAssertEqual(ftruncate(fd, off_t(ConfigurationSnapshot.maximumFileBytes + 1)), 0)
            XCTAssertThrowsError(try engine.capture())
        }
    }
}

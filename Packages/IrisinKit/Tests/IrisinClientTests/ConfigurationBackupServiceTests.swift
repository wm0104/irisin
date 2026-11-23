import Darwin
import Foundation
@testable import IrisinClient
import IrisinInstaller
import IrisinProtocol
import XCTest

final class ConfigurationBackupServiceTests: XCTestCase {
    /// Only the XPC transport is replaced; the public app service, closed job,
    /// real helper runner, descriptor codec and user-directory storage all run.
    private func service(root: URL) -> ConfigurationBackupService {
        ConfigurationBackupService { job, descriptor in
            var ends: [Int32] = [-1, -1]
            guard pipe(&ends) == 0 else { throw ConfigurationDirectory.failure() }
            let output = FileHandle(fileDescriptor: ends[1], closeOnDealloc: true)
            let runner = InstallerRunner(installRoot: root.path) { event in
                try? output.write(contentsOf: Data((InstallerOutput.encode(event) + "\n").utf8))
            }
            runner.configurationDescriptor = descriptor
            let status = runner.run(job)
            try output.write(contentsOf: Data((InstallerOutput.encode(.exit(status)) + "\n").utf8))
            try output.close()
            return JobTranscript(identifier: 1, descriptor: ends[0])
        }
    }

    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for path in ["var/mobile/Library/Preferences", "etc/apt/sources.list.d", "backups"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try Data("saved".utf8).write(to: root.appendingPathComponent("var/mobile/Library/Preferences/value"))
        return (root, root.appendingPathComponent("backups"))
    }

    func testPublicServiceBackupRestoreAndTwoCopyRetentionLeaveOtherFilesUntouched() async throws {
        let (root, backups) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = service(root: root)
        let unrelated = backups.appendingPathComponent("family-document.txt")
        try Data("keep me".utf8).write(to: unrelated)
        let invalidOwnName = backups.appendingPathComponent("Irisin-Configuration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: invalidOwnName, withIntermediateDirectories: false)
        try Data("not a backup".utf8).write(to: invalidOwnName.appendingPathComponent("keep"))
        let first = try await service.create(in: backups, allowPruning: false)
        let source = backups.appendingPathComponent("Dopamine-manual")
        try FileManager.default.copyItem(at: first.url, to: source)
        // This is a valid source v2 archive, not an Irisin-owned retention candidate.
        var sourceManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("manifest.json"))) as! [String: Any]
        sourceManifest.removeValue(forKey: "producer")
        sourceManifest.removeValue(forKey: "identifier")
        sourceManifest.removeValue(forKey: "digests")
        try JSONSerialization.data(withJSONObject: sourceManifest).write(to: source.appendingPathComponent("manifest.json"))
        _ = try await service.create(in: backups, allowPruning: false)
        _ = try await service.create(in: backups, allowPruning: false)
        XCTAssertEqual(try ConfigurationBackupStorage.records(in: backups).count, 4)
        let newest = try await service.create(in: backups, allowPruning: true)
        XCTAssertNil(newest.cleanupWarning)
        let records = try ConfigurationBackupStorage.records(in: backups)
        XCTAssertEqual(records.count, 3) // two Irisin archives and untouched source archive
        XCTAssertTrue(records.contains { $0.url == newest.url })
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: invalidOwnName.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep me".utf8))
        let live = root.appendingPathComponent("var/mobile/Library/Preferences/value")
        try Data("changed".utf8).write(to: live)
        try Data().write(to: live.deletingLastPathComponent().appendingPathComponent("target-only"))
        try await service.restore(from: newest.url, preferences: true, sources: false)
        XCTAssertEqual(try Data(contentsOf: live), Data("saved".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.deletingLastPathComponent().appendingPathComponent("target-only").path))
        XCTAssertEqual(try ConfigurationBackupStorage.records(in: backups).count, 3)
        // d047 v2's common format works through the same real restore entry.
        try await service.restore(from: source, preferences: true, sources: false)
    }

    func testLoadRejectsUndeclaredFilesLinksTamperedContentAndRetiredScope() async throws {
        let (root, backups) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = service(root: root)
        let record = try await service.create(in: backups, allowPruning: false)
        let value = record.url.appendingPathComponent("config/Preferences/value")
        let extra = record.url.appendingPathComponent("config/Preferences/undeclared")
        try Data().write(to: extra)
        XCTAssertThrowsError(try ConfigurationBackupStorage.load(from: record.url))
        try FileManager.default.removeItem(at: extra)
        try Data("tampered".utf8).write(to: value)
        XCTAssertThrowsError(try ConfigurationBackupStorage.load(from: record.url))
        try FileManager.default.removeItem(at: value)
        try FileManager.default.createSymbolicLink(at: value, withDestinationURL: root.appendingPathComponent("var/mobile/Library/Preferences/value"))
        XCTAssertThrowsError(try ConfigurationBackupStorage.load(from: record.url))
        try FileManager.default.removeItem(at: value)
        try Data("saved".utf8).write(to: value)
        let retired = record.url.appendingPathComponent("config/Filza")
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: false)
        XCTAssertThrowsError(try ConfigurationBackupStorage.load(from: record.url))
    }

    func testShortDatedNamesAvoidCollisionsAndOldBackupsRemainReadable() async throws {
        let localDate = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 12)))
        XCTAssertEqual(ConfigurationBackupRecord.name(for: localDate), "配置备份_11-21")
        let (root, backups) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = service(root: root)
        let first = try await service.create(in: backups, allowPruning: false)
        XCTAssertEqual(first.url.lastPathComponent, ConfigurationBackupRecord.name(for: first.created))
        XCTAssertEqual(first.displayName, first.url.lastPathComponent)
        XCTAssertFalse(first.displayName.contains("\n"))
        let second = try await service.create(in: backups, allowPruning: false)
        let base = ConfigurationBackupRecord.name(for: second.created)
        XCTAssertEqual(second.url.lastPathComponent, base == first.url.lastPathComponent ? base + "_2" : base)
        let saved = try ConfigurationBackupStorage.load(from: first.url)
        XCTAssertEqual(saved.manifest.archiveName, first.url.lastPathComponent)
        XCTAssertNotNil(saved.manifest.identifier.flatMap(UUID.init(uuidString:)))
        // A valid old UUID-named backup still loads; it is never renamed by listing.
        let legacy = backups.appendingPathComponent("Irisin-Configuration-" + saved.manifest.identifier!, isDirectory: true)
        try FileManager.default.copyItem(at: first.url, to: legacy)
        let manifestURL = legacy.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        manifest.removeValue(forKey: "archiveName")
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        _ = try ConfigurationBackupStorage.load(from: legacy)
        let records = try ConfigurationBackupStorage.records(in: backups)
        let old = try XCTUnwrap(records.first { $0.url == legacy })
        XCTAssertEqual(old.displayName, ConfigurationBackupRecord.name(for: old.created))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        // A renamed copy cannot acquire retention ownership from its date-like name.
        let renamed = backups.appendingPathComponent(base + "_900")
        try FileManager.default.copyItem(at: first.url, to: renamed)
        let occupied = backups.appendingPathComponent(base + "_3")
        try Data("unrelated".utf8).write(to: occupied)
        let newest = try await service.create(in: backups, allowPruning: true)
        XCTAssertNotEqual(newest.url, occupied)
        XCTAssertEqual(try Data(contentsOf: occupied), Data("unrelated".utf8))
        let remaining = try ConfigurationBackupStorage.records(in: backups)
        XCTAssertEqual(remaining.count, 3) // two owned backups, plus the renamed copy
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
    }

    func testFailedNewBackupNeverPrunesExistingArchives() async throws {
        let (root, backups) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = service(root: root)
        for _ in 0 ..< 3 { _ = try await service.create(in: backups, allowPruning: false) }
        let invalid = root.appendingPathComponent("var/mobile/Library/Preferences/invalid")
        try FileManager.default.createSymbolicLink(at: invalid, withDestinationURL: backups)
        do {
            _ = try await service.create(in: backups, allowPruning: true)
            XCTFail("unsafe capture must fail")
        } catch {}
        XCTAssertEqual(try ConfigurationBackupStorage.records(in: backups).count, 3)
    }
}

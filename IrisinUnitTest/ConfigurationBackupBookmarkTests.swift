import Foundation
@testable import irisin
import Testing

@MainActor
struct ConfigurationBackupBookmarkTests {
    @Test
    func selectionPersistsAndConsentDoesNotFollowAnotherFolder() async throws {
        let suite = "backup-ui.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let store = ConfigurationBackupDirectory(defaults: defaults)
        try store.select(root)
        let firstID = try #require(store.selectionID)
        try store.acceptRetention(for: firstID)
        #expect(store.retentionAccepted)
        #expect(ConfigurationBackupDirectory(defaults: defaults).retentionAccepted)
        try store.select(second)
        #expect(!store.retentionAccepted)
        #expect(throws: (any Error).self) { try store.acceptRetention(for: firstID) }
        let resolved = try await store.withAccess { $0 }
        #expect(resolved.standardizedFileURL == second.standardizedFileURL)
    }
}

@MainActor
extension ConfigurationBackupBookmarkTests {
    @Test
    func scopeSpansSuspensionAndReleasesOnFailureAndCancellation() async throws {
        let fixture = try BackupDirectoryFixture()
        defer { fixture.close() }
        var active = 0
        var starts = 0
        var stops = 0
        var access = ConfigurationBackupDirectory.Access()
        access.start = { _ in active += 1; starts += 1; return true }
        access.stop = { _ in active -= 1; stops += 1 }
        let store = ConfigurationBackupDirectory(defaults: fixture.defaults, access: access)
        try store.select(fixture.root)
        #expect(active == 0)
        let result = try await store.withAccess { _ in
            #expect(active == 1)
            await Task.yield()
            #expect(active == 1)
            return 42
        }
        #expect(result == 42)
        do {
            try await store.withAccess { _ in throw CancellationError() }
            Issue.record("Cancellation must propagate")
        } catch is CancellationError {}
        #expect(active == 0)
        #expect(starts == 4)
        #expect(stops == 4)
    }

    @Test
    func staleAndCorruptBookmarksNeverFallBackOrStartWork() async throws {
        let fixture = try BackupDirectoryFixture()
        defer { fixture.close() }
        try fixture.store.select(fixture.root)
        var starts = 0
        var work = 0
        var access = ConfigurationBackupDirectory.Access()
        access.resolve = { _ in (fixture.root, true) }
        access.start = { _ in starts += 1; return true }
        let stale = ConfigurationBackupDirectory(defaults: fixture.defaults, access: access)
        do {
            try await stale.withAccess { _ in work += 1 }
            Issue.record("Stale permission must fail")
        } catch {}
        fixture.defaults.set(Data("invalid".utf8), forKey: ConfigurationBackupDirectory.key)
        do {
            try await fixture.store.withAccess { _ in work += 1 }
            Issue.record("Corrupt permission must fail")
        } catch {}
        #expect(starts == 0)
        #expect(work == 0)
    }

    @Test
    func invalidSelectionPreservesGrantConsentAndUnrelatedFiles() async throws {
        let fixture = try BackupDirectoryFixture()
        defer { fixture.close() }
        try fixture.store.select(fixture.root)
        let id = try #require(fixture.store.selectionID)
        try fixture.store.acceptRetention(for: id)
        let userFile = fixture.root.appendingPathComponent("user-file")
        try Data("keep me".utf8).write(to: userFile)
        #expect(throws: (any Error).self) { try fixture.store.select(userFile) }
        let link = fixture.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root)
        #expect(throws: (any Error).self) { try fixture.store.select(link) }
        #expect(throws: (any Error).self) { try fixture.store.select(URL(string: "https://example.test/folder")!) }
        #expect(fixture.store.selectionID == id)
        #expect(fixture.store.retentionAccepted)
        #expect(try Data(contentsOf: userFile) == Data("keep me".utf8))
    }

    @Test
    func changingSelectionDuringAwaitDoesNotRedirectTheActiveGrant() async throws {
        let fixture = try BackupDirectoryFixture()
        defer { fixture.close() }
        let second = fixture.root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try fixture.store.select(fixture.root)
        let first = try await fixture.store.withAccess { url in
            try fixture.store.select(second)
            await Task.yield()
            return url
        }
        #expect(first.standardizedFileURL == fixture.root.standardizedFileURL)
        let next = try await fixture.store.withAccess { $0 }
        #expect(next.standardizedFileURL == second.standardizedFileURL)
    }
}

@MainActor
final class BackupDirectoryFixture {
    let suite = "backup-ui.\(UUID().uuidString)"
    let defaults: UserDefaults
    let root: URL
    let store: ConfigurationBackupDirectory

    init(access: ConfigurationBackupDirectory.Access = .init()) throws {
        defaults = UserDefaults(suiteName: suite)!
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ConfigurationBackupDirectory(defaults: defaults, access: access)
    }

    func close() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
extension ConfigurationBackupBookmarkTests {
    @Test
    func redirectedBookmarkCannotInheritAnotherFoldersRetentionConsent() async throws {
        let fixture = try BackupDirectoryFixture()
        defer { fixture.close() }
        let other = fixture.root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try fixture.store.select(fixture.root)
        try fixture.store.acceptRetention(for: #require(fixture.store.selectionID))
        var access = ConfigurationBackupDirectory.Access()
        access.resolve = { _ in (other, false) }
        let redirected = ConfigurationBackupDirectory(defaults: fixture.defaults, access: access)
        var work = 0
        do {
            try await redirected.withAccess { _ in work += 1 }
            Issue.record("A different inode must not inherit permission or retention consent")
        } catch {}
        #expect(work == 0)
    }

    @Test
    func replacingTheFolderAtTheSamePathDoesNotInheritConsent() async throws {
        let fixture = try BackupDirectoryFixture()
        defer { fixture.close() }
        let selected = fixture.root.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        var access = ConfigurationBackupDirectory.Access()
        access.resolve = { _ in (selected, false) }
        let store = ConfigurationBackupDirectory(defaults: fixture.defaults, access: access)
        try store.select(selected)
        try store.acceptRetention(for: #require(store.selectionID))
        try FileManager.default.moveItem(at: selected, to: fixture.root.appendingPathComponent("old"))
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        var work = 0
        do {
            try await store.withAccess { _ in work += 1 }
            Issue.record("A replacement directory must not inherit consent")
        } catch {}
        #expect(work == 0)
    }

    @Test
    func directoryPolicyRejectsSystemBootstrapAndSourcePaths() {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("backup-policy")
        #expect(ConfigurationBackupDirectory.isAllowedDataFolder(temporary.path, installRoots: []))
        #expect(!ConfigurationBackupDirectory.isAllowedDataFolder("/System", installRoots: []))
        #expect(!ConfigurationBackupDirectory.isAllowedDataFolder("/var/mobile/Library/Preferences", installRoots: [""]))
        #expect(!ConfigurationBackupDirectory.isAllowedDataFolder(temporary.appendingPathComponent(".jbroot-123/data").path, installRoots: []))
        #expect(!ConfigurationBackupDirectory.isAllowedDataFolder(temporary.appendingPathComponent("bootstrap/backups").path, installRoots: [temporary.appendingPathComponent("bootstrap").path]))
        let source = temporary.appendingPathComponent("bootstrap/var/mobile/Library/Preferences/backups")
        #expect(!ConfigurationBackupDirectory.isAllowedDataFolder(source.path, installRoots: [temporary.appendingPathComponent("bootstrap").path]))
    }

    @Test
    func failedBookmarkRoundTripDoesNotReplaceThePreviousGrant() throws {
        let fixture = try BackupDirectoryFixture()
        defer { fixture.close() }
        try fixture.store.select(fixture.root)
        let id = fixture.store.selectionID
        var access = ConfigurationBackupDirectory.Access()
        access.resolve = { _ in throw CancellationError() }
        let invalid = ConfigurationBackupDirectory(defaults: fixture.defaults, access: access)
        #expect(throws: (any Error).self) { try invalid.select(fixture.root) }
        #expect(fixture.store.selectionID == id)
    }
}

import Foundation
@testable import irisin
@testable import IrisinClient
import Testing
import UIKit
import UniformTypeIdentifiers

@MainActor
struct ConfigurationBackupUIBehaviorTests {
    @Test
    func retentionMustBeConfirmedBeforeServiceStartsAndListIsNewestFirst() async throws {
        let fixture = try BackupDirectoryFixture()
        defer { fixture.close() }
        try fixture.store.select(fixture.root)
        var creates = 0
        let older = ConfigurationBackupRecord(url: fixture.root.appendingPathComponent("older"), created: Date(timeIntervalSince1970: 1))
        let newer = ConfigurationBackupRecord(url: fixture.root.appendingPathComponent("newer"), created: Date(timeIntervalSince1970: 2))
        let model = ConfigurationBackupModel(directory: fixture.store, operations: .init(
            records: { _ in [older, newer] },
            create: { url, prune in
                #expect(url.standardizedFileURL == fixture.root.standardizedFileURL)
                #expect(prune)
                creates += 1
                return newer
            },
            restore: { _, _, _ in Issue.record("No restore was requested") }
        ))
        do {
            _ = try await model.create()
            Issue.record("Missing retention consent must block create")
        } catch {}
        #expect(creates == 0)
        #expect(!model.isBusy)
        try fixture.store.acceptRetention(for: #require(fixture.store.selectionID))
        _ = try await model.create()
        #expect(creates == 1)
        #expect(!model.isBusy)
        try await model.reload()
        #expect(model.records.map(\.url) == [newer.url, older.url])
    }

    @Test
    func restoreForwardsOnlyTheChosenCategoriesWithoutRelistingThePayload() async throws {
        let fixture = try BackupDirectoryFixture()
        defer { fixture.close() }
        try fixture.store.select(fixture.root)
        let record = ConfigurationBackupRecord(url: fixture.root.appendingPathComponent("backup"), created: .now)
        var scans = 0
        var choices: [(Bool, Bool)] = []
        let model = ConfigurationBackupModel(directory: fixture.store, operations: .init(
            records: { _ in scans += 1; return [record] },
            create: { _, _ in throw CancellationError() },
            restore: { url, preferences, sources in
                #expect(url == record.url)
                choices.append((preferences, sources))
            }
        ))
        try await model.reload()
        try await model.restore(record, preferences: true, sources: false)
        try await model.restore(record, preferences: false, sources: true)
        try await model.restore(record, preferences: true, sources: true)
        #expect(scans == 1)
        #expect(choices.count == 3)
        #expect(choices[0].0 && !choices[0].1)
        #expect(!choices[1].0 && choices[1].1)
        #expect(choices[2].0 && choices[2].1)
        do {
            try await model.restore(record, preferences: false, sources: false)
            Issue.record("An empty restore is not an operation")
        } catch {}
        #expect(choices.count == 3)
    }

    @Test
    func runningOperationKeepsScopeAndRejectsOverlapThenUnlocksAfterFailure() async throws {
        var active = 0
        var access = ConfigurationBackupDirectory.Access()
        access.start = { _ in active += 1; return true }
        access.stop = { _ in active -= 1 }
        let fixture = try BackupDirectoryFixture(access: access)
        defer { fixture.close() }
        try fixture.store.select(fixture.root)
        try fixture.store.acceptRetention(for: #require(fixture.store.selectionID))
        var finish: CheckedContinuation<Void, Never>?
        var calls = 0
        let model = ConfigurationBackupModel(directory: fixture.store, operations: .init(
            records: { _ in [] },
            create: { _, _ in
                calls += 1
                #expect(active == 1)
                await withCheckedContinuation { finish = $0 }
                #expect(active == 1)
                throw CancellationError()
            },
            restore: { _, _, _ in Issue.record("No restore was requested") }
        ))
        let first = Task { try await model.create() }
        for _ in 0 ..< 1000 {
            if finish != nil { break }
            await Task.yield()
        }
        let completion = try #require(finish)
        #expect(model.isBusy)
        do {
            _ = try await model.create()
            Issue.record("Overlapping operation must fail")
        } catch {}
        #expect(calls == 1)
        completion.resume()
        do { _ = try await first.value; Issue.record("Fixture failure must propagate") }
        catch is CancellationError {}
        #expect(!model.isBusy)
        #expect(active == 0)
        try await model.reload()
        #expect(!model.isBusy)
    }

    @Test
    func selectingAnotherFolderCannotRestoreAStaleHistoryRow() async throws {
        let fixture = try BackupDirectoryFixture()
        defer { fixture.close() }
        try fixture.store.select(fixture.root)
        let record = ConfigurationBackupRecord(url: fixture.root.appendingPathComponent("backup"), created: .now)
        var restores = 0
        let model = ConfigurationBackupModel(directory: fixture.store, operations: .init(
            records: { _ in [record] },
            create: { _, _ in throw CancellationError() },
            restore: { _, _, _ in restores += 1 }
        ))
        try await model.reload()
        let second = fixture.root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try fixture.store.select(second)
        do {
            try await model.restore(record, preferences: true, sources: true)
            Issue.record("A history row from another grant must not restore")
        } catch {}
        #expect(restores == 0)
    }

    @Test
    func controllerUsesGroupedDiffableRowsAndClosedNativeRestoreMenu() throws {
        let fixture = try BackupDirectoryFixture()
        defer { fixture.close() }
        let model = ConfigurationBackupModel(directory: fixture.store, operations: .init(
            records: { _ in [] },
            create: { _, _ in throw CancellationError() },
            restore: { _, _, _ in Issue.record("Building a page must not restore") }
        ))
        let page = ConfigurationBackupController(model: model, backendAvailable: { false }, confirmOwner: { false })
        page.loadViewIfNeeded()
        #expect(page.tableView.style == .insetGrouped)
        #expect(page.tableView.dataSource is UITableViewDiffableDataSource<ConfigurationBackupController.Section, ConfigurationBackupController.Row>)
        let menu = page.restoreMenu(for: fixture.root.appendingPathComponent("backup"))
        #expect(menu.count == 3)
        #expect(menu.allSatisfy { ($0 as? UIAction)?.attributes.contains(.destructive) == false })
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        page.documentPickerWasCancelled(picker)
        #expect(!fixture.store.hasSelection)
        #expect(!model.isBusy)
    }
}

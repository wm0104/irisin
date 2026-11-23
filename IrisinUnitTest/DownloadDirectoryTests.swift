import Foundation
@testable import irisin
import XCTest

final class DownloadDirectoryTests: XCTestCase {
    private var root: URL!
    private var defaults: Stored<Data>!
    private var suite: String!

    override func setUpWithError() throws {
        suite = "download-tests.\(UUID().uuidString)"
        defaults = Stored(key: suite, defaultValue: Data())
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        SettingStore().write(key: suite, value: nil)
        try FileManager.default.removeItem(at: root)
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testSwitchPersistsAndDoesNotRedirectAnActiveLease() throws {
        let first = try folder("first")
        let second = try folder("second")
        try DownloadDirectory.select(first, store: defaults)
        let active = try DownloadDirectory.acquire(store: defaults)
        try DownloadDirectory.select(second, store: defaults)
        XCTAssertEqual(active.url.standardizedFileURL, first.standardizedFileURL)
        XCTAssertEqual(try DownloadDirectory.acquire(store: defaults).url.standardizedFileURL, second.standardizedFileURL)
        let reopened = Stored<Data>(key: suite, defaultValue: Data())
        XCTAssertEqual(try DownloadDirectory.acquire(store: reopened).url.standardizedFileURL, second.standardizedFileURL)
    }

    func testInvalidSelectionLeavesPreviousConfiguration() throws {
        let first = try folder("first")
        try DownloadDirectory.select(first, store: defaults)
        let file = root.appendingPathComponent("not-a-folder")
        try Data("file".utf8).write(to: file)
        XCTAssertThrowsError(try DownloadDirectory.select(file, store: defaults))
        XCTAssertEqual(try DownloadDirectory.acquire(store: defaults).url.standardizedFileURL, first.standardizedFileURL)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        XCTAssertThrowsError(try DownloadDirectory.select(link, store: defaults))
    }

    func testInvalidBookmarkDoesNotFallBack() throws {
        let first = try folder("first")
        try DownloadDirectory.select(first, store: defaults)
        defaults.wrappedValue = try JSONEncoder().encode(DownloadDirectory.Configuration(url: first, bookmark: Data("bad".utf8)))
        XCTAssertThrowsError(try DownloadDirectory.acquire(store: defaults))
    }

    func testClearOnlyRemovesUnchangedManagedFile() throws {
        let directory = try folder("mixed")
        try DownloadDirectory.select(directory, store: defaults)
        let lease = try DownloadDirectory.acquire(store: defaults)
        let managed = directory.appendingPathComponent("managed.deb")
        let unrelated = directory.appendingPathComponent("user.deb")
        try Data("managed".utf8).write(to: managed)
        try Data("user".utf8).write(to: unrelated)
        let record = try DownloadDirectory.record(managed, lease: lease)
        XCTAssertEqual(try DownloadDirectory.remove(record, lease: lease), true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testTamperedAndReplacedFilesAreNeverDeleted() throws {
        let directory = try folder("mixed")
        try DownloadDirectory.select(directory, store: defaults)
        let lease = try DownloadDirectory.acquire(store: defaults)
        let file = directory.appendingPathComponent("managed.deb")
        try Data("original".utf8).write(to: file)
        let record = try DownloadDirectory.record(file, lease: lease)
        try Data("modified".utf8).write(to: file)
        XCTAssertFalse(try DownloadDirectory.remove(record, lease: lease))
        try FileManager.default.removeItem(at: file)
        let target = root.appendingPathComponent("user-data")
        try Data("original".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try DownloadDirectory.record(file, lease: lease))
        XCTAssertFalse(try DownloadDirectory.remove(record, lease: lease))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testRecordKeepsItsOwnDirectoryAcrossSelectionAndPersistence() throws {
        let first = try folder("first")
        let second = try folder("second")
        try DownloadDirectory.select(first, store: defaults)
        let lease = try DownloadDirectory.acquire(store: defaults)
        let file = first.appendingPathComponent("archive.deb")
        try Data("first".utf8).write(to: file)
        let stored = try JSONEncoder().encode(DownloadDirectory.record(file, lease: lease))
        try DownloadDirectory.select(second, store: defaults)
        try Data("unrelated".utf8).write(to: second.appendingPathComponent("archive.deb"))
        let record = try JSONDecoder().decode(DownloadDirectory.FileRecord.self, from: stored)
        let restored = try DownloadDirectory.acquire(record.configuration)
        XCTAssertEqual(restored.url.standardizedFileURL, first.standardizedFileURL)
        XCTAssertTrue(try DownloadDirectory.remove(record, lease: restored))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.appendingPathComponent("archive.deb").path))
    }
}

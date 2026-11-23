//
//  Downloads.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/24.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import Dog
import Foundation

/// Package downloads: hands URLs to `Downloader`, checks what comes back
/// against the hash the repository published and keeps the files that pass.
///
/// The bookkeeping — which download stands where, which file belongs to which
/// URL — is main-actor state and posts from there; hashing and moving files
/// takes a copy off the main actor.
///
/// A cached file is never trusted on age alone. It is hashed again every time
/// it is picked up: before a download is skipped, and before it is handed to
/// the installer. A mismatch means the repository moved a new build under the
/// same URL, so the file goes and the download runs again.
final class Downloads {
    /// One download's state, read back through `status(for:)`.
    nonisolated struct Status: Equatable, Sendable {
        let package: Package
        let url: URL
        var completedBytes: Int64 = 0
        var totalBytes: Int64 = 0
        var bytesPerSecond: Int64 = 0
        /// Nothing more will happen to this download: it has a file, or an error.
        var completed: Bool {
            file != nil || errorDescription != nil
        }

        var file: URL?
        var errorDescription: String?
        /// This attempt took the network path rather than reusing a cached file.
        var fetched: Bool = false

        /// Never above 1. The downloader fails a transfer that outgrows its
        /// own `Content-Length`; this only guards the guess that stands in
        /// for the total while the server has not given one.
        var fractionCompleted: Double {
            guard totalBytes > 0 else { return 0 }
            return min(Double(completedBytes) / Double(totalBytes), 1)
        }
    }

    nonisolated static let shared = Downloads()

    /// Where a verified .deb waits for the installer.
    nonisolated var workingLocation: URL? { DownloadDirectory.currentURL }

    private var statuses: [URL: Status] = [:]
    /// A download in flight and the token its task clears the slot with.
    private struct Running {
        let token: UUID
        let task: Task<Void, Never>
        var fetched = false
    }

    private var running: [URL: Running] = [:]
    /// What the queue's plan needs, and what Download Archive asked for. A
    /// download neither wants is stopped.
    private var queued: Set<URL> = []
    private var archived: Set<URL> = []

    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter
    }()

    private let completedStore = Stored(key: "download.completed", defaultValue: Data())

    /// Download URL to the verified file it produced.
    var completedFiles: [URL: URL] {
        get { (try? JSONDecoder().decode([URL: URL].self, from: completedStore.wrappedValue)) ?? [:] }
        set { completedStore.wrappedValue = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    private nonisolated init() {}

    private let managedStore = Stored(key: "download.managed", defaultValue: Data())
    private var fileLeases: [URL: DownloadDirectory.Lease] = [:]
    private var fileGeneration = UUID()

    private var managedFiles: [URL: DownloadDirectory.FileRecord] {
        get { (try? JSONDecoder().decode([URL: DownloadDirectory.FileRecord].self, from: managedStore.wrappedValue)) ?? [:] }
        set { managedStore.wrappedValue = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    /// Counts only the app's records, never the contents of a user's folder.
    var managedByteCount: Int64 { managedFiles.values.reduce(0) { $0 + max(0, $1.size) } }

    /// Preserve each actual landing location. Unavailable bookmarks stay on
    /// record so using the file reports an error instead of silently relocating.
    func load() async {
        for (url, record) in managedFiles {
            if let lease = try? DownloadDirectory.acquire(record.configuration) {
                fileLeases[url] = lease
                completedFiles[url] = lease.url.appendingPathComponent(record.url.lastPathComponent)
            }
        }
        Dog.shared.join(self, "reporting \(completedFiles.count) download caches")
    }

    /// Cancels first; late callbacks cannot publish into the cleared generation.
    /// Legacy records have no ownership evidence and are forgotten, not deleted.
    @discardableResult
    func clear() -> Task<Bool, Never> {
        fileGeneration = UUID()
        for entry in running.values { entry.task.cancel() }
        running = [:]
        queued = []
        archived = []
        statuses = [:]
        let records = managedFiles
        let leases = fileLeases
        completedFiles = [:]
        managedFiles = [:]
        fileLeases = [:]
        PartialDownloads.clear()
        return Task { await Self.removeRecords(records, leases: leases) }
    }

    @concurrent
    private nonisolated static func removeRecords(
        _ records: [URL: DownloadDirectory.FileRecord],
        leases: [URL: DownloadDirectory.Lease]
    ) async -> Bool {
        var untouched = false
        for (url, record) in records {
            do {
                let lease = try leases[url] ?? DownloadDirectory.acquire(record.configuration)
                if try !DownloadDirectory.remove(record, lease: lease) { untouched = true }
            } catch { untouched = true }
        }
        return !untouched
    }

    func status(for url: URL) -> Status? {
        statuses[url]
    }

    /// Whether a download is still in flight, so a page that asked for it
    /// can tell a stall from a download another page cancelled.
    func isDownloading(_ url: URL) -> Bool {
        running[url] != nil
    }

    /// A running attempt supersedes any status left by its predecessor.
    func hasStartedTransfer(for url: URL) -> Bool {
        running[url]?.fetched ?? statuses[url]?.fetched ?? false
    }

    func byteFormat(bytes: Int64) -> String {
        bytes > 0 ? byteFormatter.string(fromByteCount: bytes) : ""
    }

    // MARK: - Requests

    /// The queue's plan: these packages download, and a download the queue
    /// asked for earlier stops unless Download Archive wants it too — the
    /// partial file stays behind for a resume.
    func download(_ packages: [Package]) {
        let packages = packages.filter { $0.localFileURL == nil }
        queued = Set(packages.map { $0.obtainDownloadLink() })
        reconcile(starting: packages)
    }

    func cancelAll() {
        download([])
    }

    /// Download Archive's file: the cache when it still verifies, a
    /// download otherwise. The queue's plan does not stop it; `release` does.
    func downloadArchive(_ package: Package) {
        archived.insert(package.obtainDownloadLink())
        reconcile(starting: [package])
    }

    /// Download Archive no longer waits for this file. A download the queue
    /// needs as well keeps going.
    func release(_ package: Package) {
        archived.remove(package.obtainDownloadLink())
        reconcile(starting: [])
    }

    private func reconcile(starting packages: [Package]) {
        let wanted = queued.union(archived)
        for (url, entry) in running where !wanted.contains(url) {
            Dog.shared.join(self, "cancelling download of \(url.lastPathComponent)")
            entry.task.cancel()
            running[url] = nil
        }
        for package in packages {
            let url = package.obtainDownloadLink()
            guard running[url] == nil else { continue }
            // a cancelled task still runs to its end; it must clear only its
            // own slot, never the slot of the download that replaced it
            let token = UUID()
            let destination = Result { try DownloadDirectory.acquire() }
            running[url] = Running(token: token, task: Task {
                await self.download(package, from: url, token: token, destination: destination)
            })
        }
    }

    private func download(
        _ package: Package,
        from url: URL,
        token: UUID,
        destination: Result<DownloadDirectory.Lease, Error>
    ) async {
        defer {
            if running[url]?.token == token {
                running[url] = nil
            }
        }

        if let cached = completedFiles[url] {
            do {
                let lease = try leaseForFile(url)
                defer { withExtendedLifetime(lease) {} }
                let valid = await Self.verify(package, at: cached)
                guard isCurrent(url, token: token) else { return }
                if valid {
                    let size = (try? FileManager.default.attributesOfItem(atPath: cached.path)[.size] as? Int64) ?? 0
                    publish(Status(package: package, url: url, completedBytes: size, totalBytes: size, file: cached))
                    return
                }
                discard(url)
            } catch {
                guard isCurrent(url, token: token) else { return }
                publish(Status(package: package, url: url, errorDescription: error.localizedDescription))
                return
            }
        }

        var status = Status(package: package, url: url, totalBytes: publishedSize(of: package))
        guard isCurrent(url, token: token) else { return }

        do {
            let lease = try destination.get()
            try DownloadDirectory.validate(lease)
            running[url]?.fetched = true
            status.fetched = true
            publish(status)
            let headers = RepositoryCenter.default.networkingHeaders
            for try await event in Downloader.download(from: url, headers: headers) {
                guard isCurrent(url, token: token) else { return }
                switch event {
                case let .progress(completedBytes, totalBytes, bytesPerSecond):
                    status.completedBytes = completedBytes
                    status.bytesPerSecond = bytesPerSecond
                    if totalBytes > 0 { status.totalBytes = totalBytes }
                    publish(status)
                case let .finished(file):
                    status.bytesPerSecond = 0
                    let record = try await Self.checkout(package, from: file, lease: lease)
                    guard isCurrent(url, token: token) else {
                        try? DownloadDirectory.remove(record, lease: lease)
                        return
                    }
                    completedFiles[url] = record.url
                    managedFiles[url] = record
                    fileLeases[url] = lease
                    status.file = record.url
                    publish(status)
                }
            }
        } catch {
            guard isCurrent(url, token: token) else { return }
            Dog.shared.join(self, "download of \(url.lastPathComponent) failed: \(error.localizedDescription)", level: .error)
            status.bytesPerSecond = 0
            status.errorDescription = error.localizedDescription
            publish(status)
        }
    }

    private func isCurrent(_ url: URL, token: UUID) -> Bool {
        !Task.isCancelled && running[url]?.token == token
    }

    private func leaseForFile(_ url: URL) throws -> DownloadDirectory.Lease {
        if let lease = fileLeases[url] { return lease }
        let configuration: DownloadDirectory.Configuration
        if let record = managedFiles[url] {
            configuration = record.configuration
        } else if let file = completedFiles[url] {
            configuration = .init(url: file.deletingLastPathComponent(), bookmark: nil)
        } else { throw DownloadDirectory.Failure.unavailable }
        let lease = try DownloadDirectory.acquire(configuration)
        fileLeases[url] = lease
        return lease
    }

    private func publish(_ status: Status) {
        statuses[status.url] = status
    }

    private func publishedSize(of package: Package) -> Int64 {
        guard let size = package.latestMetadata?["size"], let value = Int64(size) else {
            return 256 * 1024 * 1024 // if the repository did not say
        }
        return value
    }

    // MARK: - Files

    /// The file to install for this package: on record, on disk, and still
    /// hashing to what the repository published. Anything else is thrown away
    /// so the next request downloads it again.
    func downloadedFile(for package: Package) async -> URL? {
        let url = package.obtainDownloadLink()
        guard let file = completedFiles[url], let lease = try? leaseForFile(url) else { return nil }
        defer { withExtendedLifetime(lease) {} }
        let generation = fileGeneration
        let valid = await Self.verify(package, at: file)
        guard generation == fileGeneration, completedFiles[url] == file else { return nil }
        guard valid else {
            Dog.shared.join(self, "dropping unusable download for \(package.identity)", level: .warning)
            discard(url)
            return nil
        }
        return file
    }

    private func discard(_ url: URL) {
        if let record = managedFiles[url], let lease = try? leaseForFile(url) {
            Task { await Self.removeRecords([url: record], leases: [url: lease]) }
        }
        managedFiles[url] = nil
        completedFiles[url] = nil
        fileLeases[url] = nil
        PartialDownloads.discard(url)
    }

    /// Does this file still hash to what the repository published? sha256 when
    /// there is one; a repository that only publishes sha1 or md5 is checked
    /// against that instead, and one that publishes nothing has to be taken on
    /// trust.
    @concurrent
    nonisolated static func verify(_ package: Package, at file: URL) async -> Bool {
        guard let data = try? DownloadDirectory.readRegular(file) else {
            Dog.shared.join("Downloads", "failed to read \(package.identity) from \(file.path)", level: .error)
            return false
        }

        let hashes: [(kind: String, expected: String?, compute: () -> String)] = [
            ("sha256", package.latestMetadata?["sha256"], { String.sha256From(data: data) }),
            ("sha1", package.latestMetadata?["sha1"], { String.sha1From(data: data) }),
            ("md5", package.latestMetadata?["md5sum"], { MD5.hex(of: data) }),
        ]
        guard let hash = hashes.first(where: { $0.expected != nil }) else {
            Dog.shared.join(
                "Downloads",
                "\(package.identity) carries no hash to check, taking it on trust",
                level: .warning
            )
            return true
        }

        let computed = hash.compute()
        guard computed == hash.expected else {
            Dog.shared.join(
                "Downloads",
                "\(package.identity) \(hash.kind) mismatch: expected \(hash.expected ?? "") got \(computed)",
                level: .error
            )
            return false
        }
        return true
    }

    /// Repository validation remains before checkout and is repeated on the
    /// copied bytes, before recording or exposing them to another consumer.
    @concurrent
    private nonisolated static func checkout(
        _ package: Package,
        from source: URL,
        lease: DownloadDirectory.Lease
    ) async throws -> DownloadDirectory.FileRecord {
        defer { try? FileManager.default.removeItem(at: source) }
        guard await verify(package, at: source) else { throw DownloadDirectory.Failure.verification }
        try Task.checkCancellation()
        let destination = fileName(for: package, in: lease.url)
        let record = try DownloadDirectory.checkout(source, named: destination.lastPathComponent, lease: lease)
        do {
            guard await verify(package, at: record.url) else { throw DownloadDirectory.Failure.verification }
            try Task.checkCancellation()
            return record
        } catch {
            try? DownloadDirectory.remove(record, lease: lease)
            throw error
        }
    }

    private nonisolated static let illegalFileNameCharacters: CharacterSet = {
        var characters = CharacterSet(charactersIn: ":/")
        characters.formUnion(.newlines)
        characters.formUnion(.illegalCharacters)
        characters.formUnion(.controlCharacters)
        return characters
    }()

    private nonisolated static func fileName(for package: Package, in directory: URL) -> URL {
        for _ in 0 ... 10 {
            let name = [
                package.identity,
                package.latestVersion ?? "0",
                String(Int.random(in: 100_000 ... 999_999)),
            ]
            .map { $0.components(separatedBy: illegalFileNameCharacters).joined() }
            .joined(separator: "_") + ".deb"
            let candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return directory.appendingPathComponent(UUID().uuidString + ".deb")
    }
}

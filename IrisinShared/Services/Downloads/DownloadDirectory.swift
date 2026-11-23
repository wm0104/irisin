import CryptoKit
import Darwin
import Foundation

/// Only completed, verified archives live here. Partial downloads and installer
/// staging deliberately keep their own locations.
nonisolated enum DownloadDirectory {
    static let key = "download.directory"
    private static let settings = Stored(key: key, defaultValue: Data())
    static var defaultURL: URL { documentsDirectory.appendingPathComponent("Downloads") }

    struct Configuration: Codable, Sendable {
        let url: URL
        let bookmark: Data?
    }

    struct FileRecord: Codable, Sendable {
        let url: URL
        let configuration: Configuration
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let digest: String
    }

    final class Lease: Sendable {
        let url: URL
        let configuration: Configuration
        let descriptor: Int32
        private let scoped: Bool

        init(url: URL, configuration: Configuration) throws {
            self.url = url
            self.configuration = configuration
            scoped = url.startAccessingSecurityScopedResource()
            descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                if scoped { url.stopAccessingSecurityScopedResource() }
                throw Failure.unavailable
            }
        }

        deinit {
            close(descriptor)
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
    }

    enum Failure: LocalizedError {
        case unavailable, changed, writeFailed, verification

        var errorDescription: String? {
            switch self {
            case .unavailable:
                String(localized: "The downloads folder is unavailable. Choose a writable local folder again.")
            case .changed:
                String(localized: "The download file or folder has changed. Irisin left it untouched.")
            case .verification:
                String(localized: "This package failed verification. Try downloading again.")
            case .writeFailed:
                String(localized: "Unable to save to the downloads folder. Choose a writable local folder.")
            }
        }
    }

    /// A snapshot for nonisolated readers, never used as write authorization.
    static var currentURL: URL? { try? configuration().url }

    static func configuration(store: Stored<Data>? = nil) throws -> Configuration {
        let data = (store ?? settings).wrappedValue
        guard !data.isEmpty else {
            return Configuration(url: defaultURL, bookmark: nil)
        }
        return try JSONDecoder().decode(Configuration.self, from: data)
    }

    static func acquire(store: Stored<Data>? = nil) throws -> Lease {
        try acquire(configuration(store: store))
    }

    static func acquire(_ configuration: Configuration) throws -> Lease {
        var url = configuration.url
        if let bookmark = configuration.bookmark {
            var stale = false
            do {
                url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale)
            } catch { throw Failure.unavailable }
            guard !stale else { throw Failure.unavailable }
        } else if url == defaultURL {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        guard url.isFileURL else { throw Failure.unavailable }
        return try Lease(url: url, configuration: configuration)
    }

    /// Commit only after the bookmark can be reopened and a private exclusive
    /// probe has demonstrated read/write access. Failure preserves the old choice.
    static func select(_ url: URL, store: Stored<Data>? = nil) throws {
        guard url.isFileURL else { throw Failure.unavailable }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let candidate = try Lease(url: url, configuration: Configuration(url: url, bookmark: nil))
        try validate(candidate)
        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let configuration = Configuration(url: url, bookmark: bookmark)
        try validate(acquire(configuration))
        (store ?? settings).wrappedValue = try JSONEncoder().encode(configuration)
    }

    static func reset(store: Stored<Data>? = nil) throws {
        let configuration = Configuration(url: defaultURL, bookmark: nil)
        try validate(acquire(configuration))
        (store ?? settings).wrappedValue = try JSONEncoder().encode(configuration)
    }

    static func validate(_ lease: Lease) throws {
        try coordinated(lease) {
            let name = ".irisin-probe-\(UUID().uuidString)"
            let fd = openat(lease.descriptor, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw Failure.writeFailed }
            defer {
                unlinkOwned(name, fd: fd, lease: lease)
                close(fd)
            }
            var byte: UInt8 = 0x49
            guard write(fd, &byte, 1) == 1, lseek(fd, 0, SEEK_SET) == 0 else { throw Failure.writeFailed }
            var readBack: UInt8 = 0
            guard read(fd, &readBack, 1) == 1, readBack == byte else { throw Failure.writeFailed }
        }
    }

    private static func unlinkOwned(_ name: String, fd: Int32, lease: Lease) {
        var held = stat()
        var current = stat()
        guard fstat(fd, &held) == 0,
              fstatat(lease.descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              held.st_dev == current.st_dev, held.st_ino == current.st_ino,
              current.st_mode & S_IFMT == S_IFREG
        else { return }
        unlinkat(lease.descriptor, name, 0)
    }

    private static func coordinated<T>(_ lease: Lease, _ body: () throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(writingItemAt: lease.url, options: [], error: &coordinationError) { url in
            var pathInfo = stat()
            var heldInfo = stat()
            guard lstat(url.path, &pathInfo) == 0, fstat(lease.descriptor, &heldInfo) == 0,
                  pathInfo.st_mode & S_IFMT == S_IFDIR,
                  pathInfo.st_dev == heldInfo.st_dev, pathInfo.st_ino == heldInfo.st_ino
            else {
                result = .failure(Failure.unavailable)
                return
            }
            result = Result { try body() }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw Failure.unavailable }
        return try result.get()
    }

    static func readRegular(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.changed }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure.changed }
        return try handle.readToEnd() ?? Data()
    }

    private static func fingerprint(_ fd: Int32) throws -> (stat, String) {
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, lseek(fd, 0, SEEK_SET) == 0
        else { throw Failure.changed }
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count >= 0 else { throw Failure.changed }
            if count == 0 { break }
            hash.update(data: Data(buffer.prefix(count)))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else { throw Failure.changed }
        return (after, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    static func record(_ file: URL, lease: Lease) throws -> FileRecord {
        guard file.deletingLastPathComponent().standardizedFileURL == lease.url.standardizedFileURL else { throw Failure.changed }
        return try coordinated(lease) {
            let fd = openat(lease.descriptor, file.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Failure.changed }
            defer { close(fd) }
            let (info, digest) = try fingerprint(fd)
            return FileRecord(url: file, configuration: lease.configuration,
                              device: UInt64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size), digest: digest)
        }
    }

    @discardableResult
    static func remove(_ record: FileRecord, lease: Lease) throws -> Bool {
        try coordinated(lease) {
            let name = record.url.lastPathComponent
            let fd = openat(lease.descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            guard let (info, digest) = try? fingerprint(fd),
                  UInt64(info.st_dev) == record.device, UInt64(info.st_ino) == record.inode,
                  Int64(info.st_size) == record.size, digest == record.digest
            else { return false }
            var current = stat()
            guard fstatat(lease.descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_dev == info.st_dev, current.st_ino == info.st_ino,
                  current.st_mode & S_IFMT == S_IFREG, current.st_nlink == 1,
                  current.st_size == info.st_size,
                  current.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
                  current.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
                  current.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec,
                  current.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec
            else { return false }
            guard unlinkat(lease.descriptor, name, 0) == 0 else { throw Failure.writeFailed }
            return true
        }
    }

    /// Copies to an exclusive private staging file, then publishes without
    /// replacing an existing name, even when another process creates it first.
    static func checkout(_ source: URL, named name: String, lease: Lease) throws -> FileRecord {
        try coordinated(lease) {
            let stage = ".irisin-checkout-\(UUID().uuidString)"
            let fd = openat(lease.descriptor, stage, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw Failure.writeFailed }
            defer {
                unlinkOwned(stage, fd: fd, lease: lease)
                close(fd)
            }
            let sourceFD = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard sourceFD >= 0 else { throw Failure.changed }
            defer { close(sourceFD) }
            var info = stat()
            guard fstat(sourceFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure.changed }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(sourceFD, &buffer, buffer.count)
                guard count >= 0 else { throw Failure.writeFailed }
                if count == 0 { break }
                try buffer.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < count {
                        let written = write(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
                        guard written > 0 else { throw Failure.writeFailed }
                        offset += written
                    }
                }
            }
            let (saved, digest) = try fingerprint(fd)
            let record = FileRecord(url: lease.url.appendingPathComponent(name), configuration: lease.configuration,
                                    device: UInt64(saved.st_dev), inode: UInt64(saved.st_ino), size: Int64(saved.st_size), digest: digest)
            guard fsync(fd) == 0,
                  renameatx_np(lease.descriptor, stage, lease.descriptor, name, UInt32(RENAME_EXCL)) == 0
            else { throw Failure.writeFailed }
            return record
        }
    }
}

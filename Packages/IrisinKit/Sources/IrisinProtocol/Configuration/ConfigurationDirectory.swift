import Darwin
import Foundation

/// Descriptor-relative, no-follow operations shared by the app's archive storage
/// and the helper. Paths are validated before their first component is opened.
public final class ConfigurationDirectory {
    public let descriptor: Int32

    public init(absolutePath: String) throws {
        guard absolutePath.hasPrefix("/") else { throw ConfigurationBackupError("Invalid directory anchor") }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure() }
        do {
            for part in absolutePath.utf8.split(separator: 0x2F) {
                let name = String(decoding: part, as: UTF8.self)
                guard ConfigurationSnapshot.validPath(name), !name.contains("/") else {
                    throw ConfigurationBackupError("Invalid directory anchor")
                }
                let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Self.failure() }
                close(fd); fd = next
            }
            descriptor = fd
        } catch {
            close(fd)
            throw error
        }
    }

    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }

    public static func failure(_ code: Int32 = errno) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private static func child(_ name: String) throws {
        guard ConfigurationSnapshot.validPath(name), !name.utf8.contains(0x2F) else {
            throw ConfigurationBackupError("Unsafe directory entry")
        }
    }

    public func info(_ name: String) throws -> stat? {
        try Self.child(name)
        var result = stat()
        guard fstatat(descriptor, name, &result, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw Self.failure()
        }
        return result
    }

    public func directory(_ name: String) throws -> ConfigurationDirectory {
        try Self.child(name)
        let fd = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure() }
        return ConfigurationDirectory(descriptor: fd)
    }

    public func descend(_ path: String, create: Bool = false) throws -> ConfigurationDirectory {
        guard ConfigurationSnapshot.validPath(path) else { throw ConfigurationBackupError("Unsafe relative path") }
        var directory = ConfigurationDirectory(descriptor: dup(descriptor))
        guard directory.descriptor >= 0 else { throw Self.failure() }
        for part in path.utf8.split(separator: 0x2F) {
            let name = String(decoding: part, as: UTF8.self)
            if create, try directory.info(name) == nil { try directory.make(name) }
            directory = try directory.directory(name)
        }
        return directory
    }

    public func names() throws -> [String] {
        // openat(".") has its own seek offset; dup would share readdir's offset.
        let fd = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure() }
        guard let stream = fdopendir(fd) else {
            let code = errno; close(fd); throw Self.failure(code)
        }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw Self.failure() }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            try Self.child(name)
            result.append(name)
            guard result.count <= ConfigurationSnapshot.maximumEntries else {
                throw ConfigurationBackupError("Too many directory entries")
            }
        }
        return result.sorted()
    }

    public func make(_ name: String) throws {
        try Self.child(name)
        guard mkdirat(descriptor, name, 0o700) == 0, fsync(descriptor) == 0 else { throw Self.failure() }
    }

    public func read(_ name: String, limit: Int = ConfigurationSnapshot.maximumFileBytes) throws -> (Data, stat) {
        try Self.child(name)
        let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure() }
        defer { close(fd) }
        return try Self.read(descriptor: fd, limit: limit)
    }

    public static func read(descriptor fd: Int32, limit: Int, allowUnlinked: Bool = false) throws -> (Data, stat) {
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              (before.st_nlink == 1 || (allowUnlinked && before.st_nlink == 0)), before.st_size >= 0, before.st_size <= limit
        else { throw ConfigurationBackupError("Link, special or oversized file rejected") }
        var data = Data(count: Int(before.st_size))
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = pread(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, off_t(offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ConfigurationBackupError("Configuration changed during read") }
                offset += count
            }
        }
        var after = stat(), extra: UInt8 = 0
        guard pread(fd, &extra, 1, before.st_size) == 0, fstat(fd, &after) == 0,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              after.st_nlink == before.st_nlink
        else { throw ConfigurationBackupError("Configuration changed during read") }
        return (data, before)
    }

    public func write(_ name: String, data: Data) throws {
        try Self.child(name)
        let fd = openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.failure() }
        defer { close(fd) }
        try Self.write(descriptor: fd, data: data)
        guard fsync(fd) == 0 else { throw Self.failure() }
    }

    public static func write(descriptor fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = pwrite(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, off_t(offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Self.failure() }
                offset += count
            }
        }
        guard ftruncate(fd, off_t(data.count)) == 0 else { throw Self.failure() }
    }

    public func rename(_ name: String, to other: ConfigurationDirectory, as destination: String) throws {
        try Self.child(name); try Self.child(destination)
        guard renameat(descriptor, name, other.descriptor, destination) == 0 else { throw Self.failure() }
    }

    /// Never traverses links, even during cleanup. Failure leaves the remainder
    /// for inspection rather than following a substituted directory or file.
    public func remove(_ name: String, depth: Int = 0) throws {
        guard depth < 64, let before = try info(name) else { return }
        if before.st_mode & S_IFMT == S_IFDIR {
            let directory = try directory(name)
            var pinned = stat()
            guard fstat(directory.descriptor, &pinned) == 0, Self.sameNode(before, pinned) else {
                throw ConfigurationBackupError("Directory changed during cleanup")
            }
            for child in try directory.names() { try directory.remove(child, depth: depth + 1) }
            guard let current = try info(name), Self.sameNode(before, current),
                  unlinkat(descriptor, name, AT_REMOVEDIR) == 0
            else { throw ConfigurationBackupError("Directory changed during cleanup") }
        } else {
            guard before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
                  unlinkat(descriptor, name, 0) == 0
            else { throw ConfigurationBackupError("Unsafe cleanup entry") }
        }
    }

    public static func sameNode(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode & S_IFMT == rhs.st_mode & S_IFMT
    }
}

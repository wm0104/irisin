import Darwin
import Foundation

public enum ConfigurationTree {
    /// Capture one allowed tree. Both root and the selected directory are pinned.
    public static func append(
        directory: ConfigurationDirectory, path: String, to snapshot: inout ConfigurationSnapshot
    ) throws {
        guard ConfigurationSnapshot.root(for: path) != nil,
              snapshot.manifest.directories.count + snapshot.files.count + 4 <= ConfigurationSnapshot.maximumEntries
        else { throw ConfigurationBackupError("Configuration entry limit or scope exceeded") }
        var before = stat()
        guard fstat(directory.descriptor, &before) == 0 else { throw ConfigurationDirectory.failure() }
        snapshot.manifest.directories.append(path)
        snapshot.manifest.metadata[path] = metadata(before)
        for name in try directory.names() {
            let child = path + "/" + name
            guard let info = try directory.info(name) else { throw ConfigurationBackupError("Configuration changed during capture") }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                try append(directory: directory.directory(name), path: child, to: &snapshot)
            case S_IFREG:
                let (data, info) = try directory.read(name)
                guard snapshot.files.count + snapshot.manifest.directories.count + 4 <= ConfigurationSnapshot.maximumEntries,
                      data.count + snapshot.files.values.reduce(0, { $0 + $1.count }) <= ConfigurationSnapshot.maximumTotalBytes
                else { throw ConfigurationBackupError("Configuration backup exceeds limit") }
                snapshot.files[child] = data
                snapshot.manifest.files.append(child)
                snapshot.manifest.metadata[child] = metadata(info)
            default:
                throw ConfigurationBackupError("Configuration links and special files are not supported")
            }
        }
        var after = stat()
        guard fstat(directory.descriptor, &after) == 0,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else { throw ConfigurationBackupError("Configuration directory changed during capture") }
    }

    public static func metadata(_ info: stat) -> ConfigurationSnapshot.Metadata {
        .init(mode: UInt32(info.st_mode & 0o777), uid: info.st_uid, gid: info.st_gid,
              seconds: Int64(info.st_mtimespec.tv_sec), nanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }

    /// Write only into a new, private directory. Metadata is kept in the manifest;
    /// the privileged restore applies it before publishing a staged tree.
    public static func write(_ snapshot: ConfigurationSnapshot, into directory: ConfigurationDirectory) throws {
        try snapshot.validate()
        for path in snapshot.manifest.directories.sorted(by: { $0.utf8.count < $1.utf8.count }) {
            _ = try directory.descend(path, create: true)
        }
        for path in snapshot.manifest.files {
            let parts = path.split(separator: "/").map(String.init)
            let parent = try directory.descend(parts.dropLast().joined(separator: "/"))
            try parent.write(parts.last!, data: snapshot.files[path]!)
        }
    }
}

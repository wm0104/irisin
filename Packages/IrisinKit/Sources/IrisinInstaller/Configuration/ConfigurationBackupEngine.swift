import Darwin
import Foundation
import IrisinProtocol

/// Fixed live roots only. The caller's only input is an already validated snapshot.
/// Temporary journals allow in-process rollback, not crash recovery guarantees.
final class ConfigurationBackupEngine {
    private let root: String
    private let layout: BootstrapLayout
    var afterPublish: ((String) throws -> Void)?
    var afterPrepare: (() throws -> Void)?

    init(root: String, layout: BootstrapLayout? = nil) {
        self.root = root.isEmpty ? "/" : root
        self.layout = layout ?? BootstrapLayout(installRoot: root)
    }

    private func anchors() throws -> (ConfigurationDirectory, ConfigurationDirectory) {
        // Only the bootstrap's trusted var anchor may resolve its platform links.
        // mobile/Library and etc/apt are then opened component-by-component, no-follow.
        guard let variable = PackageFilesystem.physicalPath(root + "/var", followingLast: true, layout: layout),
              let canonicalRoot = ProcessPath.canonical(root)
        else { throw ConfigurationBackupError("Configuration anchors are unavailable") }
        let variableDirectory = try ConfigurationDirectory(absolutePath: variable)
        let rootDirectory = try ConfigurationDirectory(absolutePath: canonicalRoot)
        return (try variableDirectory.descend("mobile/Library"), try rootDirectory.descend("etc/apt"))
    }

    private func locked<T>(_ action: (ConfigurationDirectory, ConfigurationDirectory) throws -> T) throws -> T {
        let (library, apt) = try anchors()
        guard flock(library.descriptor, LOCK_EX | LOCK_NB) == 0 else { throw ConfigurationDirectory.failure() }
        defer { flock(library.descriptor, LOCK_UN) }
        guard flock(apt.descriptor, LOCK_EX | LOCK_NB) == 0 else { throw ConfigurationDirectory.failure() }
        defer { flock(apt.descriptor, LOCK_UN) }
        return try action(library, apt)
    }

    func capture() throws -> ConfigurationSnapshot {
        try locked { library, apt in
            var snapshot = ConfigurationSnapshot(manifest: .init(files: [], directories: [], metadata: [:]), files: [:])
            for path in ConfigurationSnapshot.roots {
                let parent = path.hasPrefix("config/") ? library : apt
                let name = String(path.split(separator: "/").last!)
                guard let before = try parent.info(name) else { continue }
                guard before.st_mode & S_IFMT == S_IFDIR else {
                    throw ConfigurationBackupError("Configuration roots must be real directories")
                }
                let directory = try parent.directory(name)
                var pinned = stat()
                guard fstat(directory.descriptor, &pinned) == 0, ConfigurationDirectory.sameNode(before, pinned) else {
                    throw ConfigurationBackupError("Configuration root changed during capture")
                }
                try ConfigurationTree.append(directory: directory, path: path, to: &snapshot)
                guard let after = try parent.info(name), ConfigurationDirectory.sameNode(before, after) else {
                    throw ConfigurationBackupError("Configuration root changed during capture")
                }
            }
            snapshot.manifest.files.sort(); snapshot.manifest.directories.sort()
            try snapshot.validate()
            return snapshot
        }
    }

    private final class Stage {
        let path: String
        let name: String
        let parent: ConfigurationDirectory
        let workName: String
        let work: ConfigurationDirectory
        let workInfo: stat
        let previous: stat?
        var previousSnapshot: ConfigurationSnapshot?
        var installed: stat?
        var movedOld = false
        var published = false

        init(path: String, parent: ConfigurationDirectory) throws {
            self.path = path; self.parent = parent
            name = String(path.split(separator: "/").last!)
            previous = try parent.info(name)
            if let previous, previous.st_mode & S_IFMT != S_IFDIR {
                throw ConfigurationBackupError("Restore target must be a real directory")
            }
            workName = ".irisin-config-" + UUID().uuidString
            try parent.make(workName)
            work = try parent.directory(workName)
            var info = stat()
            guard fstat(work.descriptor, &info) == 0, info.st_uid == geteuid(),
                  info.st_mode & 0o777 == 0o700,
                  let named = try parent.info(workName), ConfigurationDirectory.sameNode(info, named)
            else { throw ConfigurationBackupError("Unsafe temporary restore directory") }
            workInfo = info
        }

        func journal(_ state: String) throws {
            let data = try JSONSerialization.data(withJSONObject: ["root": path, "state": state])
            try work.write("journal-next.json", data: data)
            try work.rename("journal-next.json", to: work, as: "journal.json")
            guard fsync(work.descriptor) == 0, fsync(parent.descriptor) == 0 else {
                throw ConfigurationDirectory.failure()
            }
        }

        func clean() throws {
            guard let info = try parent.info(workName), ConfigurationDirectory.sameNode(workInfo, info) else {
                throw ConfigurationBackupError("Temporary restore directory moved; cleanup incomplete")
            }
            try parent.remove(workName)
            guard fsync(parent.descriptor) == 0 else { throw ConfigurationDirectory.failure() }
        }
    }

    func restore(_ snapshot: ConfigurationSnapshot, preferences: Bool, sources: Bool) throws {
        try snapshot.validate()
        guard preferences || sources else { throw ConfigurationBackupError("Select configuration or sources to restore") }
        let selected = ConfigurationSnapshot.roots.filter {
            snapshot.manifest.directories.contains($0) && ($0.hasPrefix("config/") ? preferences : sources)
        }
        guard !selected.isEmpty else { throw ConfigurationBackupError("No saved directories match this selection") }
        try locked { library, apt in
            var stages: [Stage] = []
            var originalBytes = 0
            var originalEntries = 0
            do {
                for path in selected {
                    let stage = try Stage(path: path, parent: path.hasPrefix("config/") ? library : apt)
                    stages.append(stage)
                    // Inspect the existing tree before moving it; no link or special entry
                    // may be smuggled into the temporary old directory's later cleanup.
                    if stage.previous != nil {
                        var current = ConfigurationSnapshot(manifest: .init(files: [], directories: [], metadata: [:]), files: [:])
                        try ConfigurationTree.append(directory: stage.parent.directory(stage.name), path: path, to: &current)
                        try current.validate()
                        originalBytes += current.files.values.reduce(0, { $0 + $1.count })
                            + (try JSONEncoder().encode(current.manifest).count)
                        originalEntries += current.files.count + current.manifest.directories.count
                        guard originalBytes <= ConfigurationSnapshot.maximumTotalBytes,
                              originalEntries + 3 <= ConfigurationSnapshot.maximumEntries else {
                            throw ConfigurationBackupError("Live configuration exceeds consistency-check limits")
                        }
                        stage.previousSnapshot = current
                    }
                    try prepare(snapshot, stage: stage)
                    try stage.journal("staged")
                }
                try afterPrepare?()
                // Writers such as cfprefsd do not participate in our lock. Re-read
                // every selected original tree after all staging, before any swap.
                for stage in stages { try verifyOriginal(stage) }
                for stage in stages {
                    try verifyOriginal(stage)
                    let current = try stage.parent.info(stage.name)
                    guard matches(stage.previous, current) else { throw ConfigurationBackupError("Restore target changed before replacement") }
                    if stage.previous != nil {
                        try stage.parent.rename(stage.name, to: stage.work, as: "old")
                        stage.movedOld = true
                        guard matches(stage.previous, try stage.work.info("old")) else {
                            throw ConfigurationBackupError("Restore target changed during replacement")
                        }
                    }
                    try stage.journal("old-moved")
                    guard try stage.parent.info(stage.name) == nil else { throw ConfigurationBackupError("Restore target reappeared during replacement") }
                    try stage.work.rename("new", to: stage.parent, as: stage.name)
                    stage.published = true
                    guard matches(stage.installed, try stage.parent.info(stage.name)) else {
                        throw ConfigurationBackupError("Restored directory changed during publication")
                    }
                    try stage.journal("published")
                    try afterPublish?(stage.path)
                }
            } catch {
                var failures: [String] = []
                for stage in stages.reversed() {
                    do {
                        if stage.published {
                            guard matches(stage.installed, try stage.parent.info(stage.name)) else {
                                throw ConfigurationBackupError("Published directory was replaced")
                            }
                            try stage.parent.rename(stage.name, to: stage.work, as: "new")
                        }
                        if stage.movedOld {
                            guard try stage.parent.info(stage.name) == nil,
                                  matches(stage.previous, try stage.work.info("old")) else {
                                throw ConfigurationBackupError("Rollback destination changed")
                            }
                            try stage.work.rename("old", to: stage.parent, as: stage.name)
                        }
                        try stage.journal("rolled-back")
                        try stage.clean()
                    } catch { failures.append(stage.path) }
                }
                if !failures.isEmpty {
                    throw ConfigurationBackupError("Restore partially applied; rollback or cleanup failed for: " + failures.joined(separator: ", "))
                }
                throw ConfigurationBackupError("Restore failed; original directories retained or rolled back: \(error.localizedDescription)")
            }
            var cleanupFailed = false
            for stage in stages {
                do { try stage.clean() } catch { cleanupFailed = true }
            }
            if cleanupFailed { throw ConfigurationBackupError("Restore completed; temporary old-directory cleanup failed") }
        }
    }

    private func verifyOriginal(_ stage: Stage) throws {
        guard matches(stage.previous, try stage.parent.info(stage.name)) else {
            throw ConfigurationBackupError("Restore target changed before replacement")
        }
        guard let previous = stage.previousSnapshot else { return }
        var current = ConfigurationSnapshot(manifest: .init(files: [], directories: [], metadata: [:]), files: [:])
        try ConfigurationTree.append(directory: stage.parent.directory(stage.name), path: stage.path, to: &current)
        try current.validate()
        guard previous.files == current.files,
              Set(previous.manifest.directories) == Set(current.manifest.directories),
              previous.manifest.metadata == current.manifest.metadata else {
            throw ConfigurationBackupError("Live configuration changed while staging; nothing further replaced")
        }
    }

    private func matches(_ expected: stat?, _ actual: stat?) -> Bool {
        switch (expected, actual) {
        case (nil, nil): true
        case let (expected?, actual?): ConfigurationDirectory.sameNode(expected, actual)
        default: false
        }
    }

    private func prepare(_ snapshot: ConfigurationSnapshot, stage: Stage) throws {
        try stage.work.make("new")
        let destination = try stage.work.directory("new")
        let prefix = stage.path + "/"
        let directories = snapshot.manifest.directories.filter { $0.utf8.starts(with: prefix.utf8) }
            .sorted { $0.utf8.count < $1.utf8.count }
        for path in directories {
            _ = try destination.descend(String(path.dropFirst(prefix.count)), create: true)
        }
        for path in snapshot.manifest.files where path.utf8.starts(with: prefix.utf8) {
            let relative = String(path.dropFirst(prefix.count))
            let parts = relative.split(separator: "/").map(String.init)
            let parent = parts.count == 1 ? destination : try destination.descend(parts.dropLast().joined(separator: "/"))
            try parent.write(parts.last!, data: snapshot.files[path]!)
            let fd = openat(parent.descriptor, parts.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw ConfigurationDirectory.failure() }
            do { try apply(snapshot.manifest.metadata[path]!, to: fd) } catch { close(fd); throw error }
            close(fd)
        }
        for path in directories.reversed() {
            let directory = try destination.descend(String(path.dropFirst(prefix.count)))
            try apply(snapshot.manifest.metadata[path]!, to: directory.descriptor)
        }
        try apply(snapshot.manifest.metadata[stage.path]!, to: destination.descriptor)
        var info = stat()
        guard fstat(destination.descriptor, &info) == 0 else { throw ConfigurationDirectory.failure() }
        stage.installed = info
    }

    private func apply(_ metadata: ConfigurationSnapshot.Metadata, to fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ConfigurationDirectory.failure() }
        // Non-root native tests can preserve their own metadata without a chown
        // their host disallows. On device the root helper always applies owners.
        if info.st_uid != metadata.uid || info.st_gid != metadata.gid {
            guard fchown(fd, metadata.uid, metadata.gid) == 0 else { throw ConfigurationDirectory.failure() }
        }
        guard fchmod(fd, mode_t(metadata.mode & 0o777)) == 0 else { throw ConfigurationDirectory.failure() }
        let time = timespec(tv_sec: Int(metadata.seconds), tv_nsec: Int(metadata.nanoseconds))
        let times = [time, time]
        guard futimens(fd, times) == 0, fsync(fd) == 0 else { throw ConfigurationDirectory.failure() }
    }
}

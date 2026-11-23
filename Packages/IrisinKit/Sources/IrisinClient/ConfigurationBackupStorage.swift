import Darwin
import Foundation
import IrisinProtocol

public struct ConfigurationBackupRecord: Sendable {
    public let url: URL
    public let created: Date
    public var cleanupWarning: String?

    public init(url: URL, created: Date, cleanupWarning: String? = nil) {
        self.url = url; self.created = created; self.cleanupWarning = cleanupWarning
    }

    public var displayName: String {
        url.lastPathComponent.hasPrefix("Irisin-Configuration-") ? Self.name(for: created) : url.lastPathComponent
    }

    static func name(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "MM-dd"
        return "配置备份_" + formatter.string(from: date)
    }
}

/// The app alone opens the user-selected directory. Nothing here sends a path
/// to root. Callers keep their security-scoped authorization alive throughout.
public enum ConfigurationBackupStorage {
    private static let producer = "wiki.qaq.irisin.configuration-backup"
    private static let namePrefix = "配置备份_"
    private static let legacyNamePrefix = "Irisin-Configuration-"

    private static func anchor(_ url: URL) throws -> ConfigurationDirectory {
        guard url.isFileURL, let path = ProcessPath.canonical(url.path) else {
            throw ConfigurationBackupError("Backup directory is unavailable")
        }
        return try ConfigurationDirectory(absolutePath: path)
    }

    public static func records(in directory: URL) throws -> [ConfigurationBackupRecord] {
        let parent = try anchor(directory)
        var result: [ConfigurationBackupRecord] = []
        for name in try parent.names() {
            guard let info = try parent.info(name), info.st_mode & S_IFMT == S_IFDIR,
                  let snapshot = try? load(parent: parent, name: name)
            else { continue }
            result.append(.init(url: directory.appendingPathComponent(name, isDirectory: true),
                                created: Date(timeIntervalSince1970: snapshot.manifest.created ?? 0)))
        }
        return result.sorted { $0.created > $1.created }
    }

    public static func load(from directory: URL) throws -> ConfigurationSnapshot {
        let parent = try anchor(directory.deletingLastPathComponent())
        return try load(parent: parent, name: directory.lastPathComponent)
    }

    private static func load(parent: ConfigurationDirectory, name: String) throws -> ConfigurationSnapshot {
        guard let before = try parent.info(name), before.st_mode & S_IFMT == S_IFDIR else {
            throw ConfigurationBackupError("Backup must be a real directory")
        }
        let directory = try parent.directory(name)
        let (json, _) = try directory.read("manifest.json")
        let manifest = try JSONDecoder().decode(ConfigurationSnapshot.Manifest.self, from: json)
        var snapshot = ConfigurationSnapshot(manifest: .init(files: [], directories: [], metadata: [:]), files: [:])
        let names = try directory.names()
        guard Set(names).isSubset(of: ["manifest.json", "config", "sources"]), names.contains("manifest.json") else {
            throw ConfigurationBackupError("Unexpected entry in backup directory")
        }
        for category in ["config", "sources"] where names.contains(category) {
            let categoryDirectory = try directory.directory(category)
            for child in try categoryDirectory.names() {
                let path = category + "/" + child
                guard ConfigurationSnapshot.roots.contains(path) else {
                    throw ConfigurationBackupError("Backup directory is outside configuration scope")
                }
                try ConfigurationTree.append(directory: categoryDirectory.directory(child), path: path, to: &snapshot)
            }
        }
        guard Set(snapshot.manifest.directories) == Set(manifest.directories),
              let after = try parent.info(name), ConfigurationDirectory.sameNode(before, after)
        else { throw ConfigurationBackupError("Backup directories do not match manifest") }
        snapshot.manifest = manifest
        try snapshot.validate()
        return snapshot
    }

    public static func publish(
        _ captured: ConfigurationSnapshot, in directory: URL, allowPruning: Bool
    ) throws -> ConfigurationBackupRecord {
        var snapshot = captured
        let identifier = UUID().uuidString
        let created = Date()
        snapshot.manifest.producer = producer
        snapshot.manifest.identifier = identifier
        snapshot.manifest.created = created.timeIntervalSince1970
        snapshot.manifest.digests = snapshot.files.mapValues(ConfigurationSnapshot.digest)
        try snapshot.validate()
        let parent = try anchor(directory)
        // Serialize list/publish/prune against another Irisin operation in this folder.
        guard flock(parent.descriptor, LOCK_EX | LOCK_NB) == 0 else { throw ConfigurationDirectory.failure() }
        defer { flock(parent.descriptor, LOCK_UN) }
        let temporary = ".irisin-publish-" + identifier
        let baseName = ConfigurationBackupRecord.name(for: created)
        var name = baseName
        var suffix = 2
        while try parent.info(name) != nil {
            name = baseName + "_" + String(suffix)
            suffix += 1
        }
        snapshot.manifest.archiveName = name
        try parent.make(temporary)
        do {
            let staging = try parent.directory(temporary)
            try ConfigurationTree.write(snapshot, into: staging)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let json = try encoder.encode(snapshot.manifest)
            guard json.count + snapshot.files.values.reduce(0, { $0 + $1.count }) <= ConfigurationSnapshot.maximumTotalBytes else {
                throw ConfigurationBackupError("Backup including manifest exceeds limit")
            }
            try staging.write("manifest.json", data: json)
            _ = try load(parent: parent, name: temporary)
            guard fsync(staging.descriptor) == 0 else { throw ConfigurationDirectory.failure() }
            guard renameatx_np(parent.descriptor, temporary, parent.descriptor, name, UInt32(RENAME_EXCL)) == 0 else {
                throw ConfigurationDirectory.failure()
            }
        } catch {
            try? parent.remove(temporary)
            throw error
        }
        var record = ConfigurationBackupRecord(url: directory.appendingPathComponent(name, isDirectory: true), created: created)
        if fsync(parent.descriptor) != 0 { record.cleanupWarning = "Backup saved; directory synchronization failed" }
        if allowPruning {
            do { try prune(parent: parent, keeping: name) } catch {
                record.cleanupWarning = "Backup saved; old backup cleanup failed"
            }
        }
        return record
    }

    private static func owned(_ snapshot: ConfigurationSnapshot, name: String) -> Bool {
        guard let identifier = snapshot.manifest.identifier,
              let uuid = UUID(uuidString: identifier), uuid.uuidString == identifier,
              snapshot.manifest.producer == producer,
              snapshot.manifest.created != nil, snapshot.manifest.digests != nil else { return false }
        if let archiveName = snapshot.manifest.archiveName {
            return name == archiveName && name.range(of: "^配置备份_[0-9]{2}-[0-9]{2}(_[0-9]+)?$", options: .regularExpression) != nil
        }
        return name == legacyNamePrefix + identifier
    }

    private static func prune(parent: ConfigurationDirectory, keeping newest: String) throws {
        var candidates: [(String, Double, stat)] = []
        for name in try parent.names() where name != newest && (name.hasPrefix(namePrefix) || name.hasPrefix(legacyNamePrefix)) {
            guard let info = try parent.info(name), info.st_mode & S_IFMT == S_IFDIR,
                  let snapshot = try? load(parent: parent, name: name), owned(snapshot, name: name)
            else { continue }
            candidates.append((name, snapshot.manifest.created!, info))
        }
        candidates.sort { $0.1 == $1.1 ? $0.0 > $1.0 : $0.1 > $1.1 }
        // Keep the new successful backup and the newest valid older Irisin backup.
        for (name, _, before) in candidates.dropFirst() {
            guard let current = try parent.info(name), ConfigurationDirectory.sameNode(before, current) else {
                throw ConfigurationBackupError("Backup changed before cleanup")
            }
            let quarantined = ".irisin-prune-" + UUID().uuidString
            try parent.rename(name, to: parent, as: quarantined)
            do {
                let verified = try load(parent: parent, name: quarantined)
                guard owned(verified, name: name), let moved = try parent.info(quarantined),
                      ConfigurationDirectory.sameNode(before, moved) else {
                    throw ConfigurationBackupError("Backup changed during cleanup")
                }
            } catch {
                if try parent.info(name) == nil { try? parent.rename(quarantined, to: parent, as: name) }
                throw error
            }
            try parent.remove(quarantined)
            guard fsync(parent.descriptor) == 0 else { throw ConfigurationDirectory.failure() }
        }
    }
}

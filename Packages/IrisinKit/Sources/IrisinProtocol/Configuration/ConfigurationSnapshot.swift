import CryptoKit
import Foundation

public struct ConfigurationBackupError: LocalizedError, Sendable {
    public let detail: String
    public init(_ detail: String) { self.detail = detail }
    public var errorDescription: String? { detail }
}

/// v2's directory/file lists and metadata match the configuration-only source format.
/// No package database, bootstrap contents, xattrs or ACLs are represented.
public struct ConfigurationSnapshot: Codable, Sendable {
    public static let roots = [
        "config/Preferences", "config/ControlCenter", "config/CallAssist",
        "config/RootHide", "config/CallAssistActivation", "config/Snapper3",
        "sources/sources.list.d",
    ]
    public static let maximumFileBytes = 32 * 1024 * 1024
    public static let maximumTotalBytes = 128 * 1024 * 1024
    public static let maximumEntries = 8192
    // Binary plist framing is separate from the small InstallerJob JSON wire.
    public static let maximumTransportBytes = maximumTotalBytes + 16 * 1024 * 1024

    public struct Metadata: Codable, Equatable, Sendable {
        public var mode: UInt32
        public var uid: UInt32
        public var gid: UInt32
        public var seconds: Int64
        public var nanoseconds: Int64

        public init(mode: UInt32, uid: UInt32, gid: UInt32, seconds: Int64, nanoseconds: Int64) {
            self.mode = mode; self.uid = uid; self.gid = gid
            self.seconds = seconds; self.nanoseconds = nanoseconds
        }
    }

    public struct Manifest: Codable, Sendable {
        public var format = "org.roothide.configuration-backup"
        public var version = 2
        public var files: [String]
        public var directories: [String]
        public var metadata: [String: Metadata]
        public var created: Double?
        public var producer: String?
        public var identifier: String?
        public var archiveName: String?
        public var digests: [String: String]?

        public init(files: [String], directories: [String], metadata: [String: Metadata]) {
            self.files = files; self.directories = directories; self.metadata = metadata
        }
    }

    public var manifest: Manifest
    public var files: [String: Data]

    public init(manifest: Manifest, files: [String: Data]) {
        self.manifest = manifest; self.files = files
    }

    public static func validPath(_ path: String) -> Bool {
        let parts = path.utf8.split(separator: 0x2F, omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.count <= 32 && path.utf8.count <= 4096
            && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0 == "\\" }
            && parts.allSatisfy { !$0.isEmpty && $0.count <= 255 && !$0.elementsEqual(".".utf8)
                && !$0.elementsEqual("..".utf8) }
    }

    public static func root(for path: String) -> String? {
        guard validPath(path) else { return nil }
        return roots.first { path == $0 || path.utf8.starts(with: ($0 + "/").utf8) }
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func validate() throws {
        let m = manifest
        let declared = Set(m.files), directories = Set(m.directories)
        guard m.format == "org.roothide.configuration-backup", m.version == 2,
              m.files.count + m.directories.count + 3 <= Self.maximumEntries,
              declared.count == m.files.count, directories.count == m.directories.count,
              declared.isDisjoint(with: directories), Set(files.keys) == declared,
              Set(m.metadata.keys) == declared.union(directories), !directories.isEmpty,
              m.created.map({ $0.isFinite && $0 >= 0 }) ?? true
        else { throw ConfigurationBackupError("Invalid configuration manifest") }
        for path in m.files + m.directories {
            guard let root = Self.root(for: path), directories.contains(root),
                  let metadata = m.metadata[path], metadata.mode <= 0o777,
                  metadata.uid != UInt32.max, metadata.gid != UInt32.max,
                  metadata.nanoseconds >= 0, metadata.nanoseconds < 1_000_000_000,
                  metadata.seconds >= 0, metadata.seconds <= 253_402_300_799
            else { throw ConfigurationBackupError("Unsafe configuration path or metadata") }
            if path != root {
                let parent = String(path[..<path.lastIndex(of: "/")!])
                guard directories.contains(parent) else { throw ConfigurationBackupError("Missing parent directory") }
            } else if declared.contains(path) {
                throw ConfigurationBackupError("Configuration roots must be directories")
            }
        }
        var total = try JSONEncoder().encode(m).count
        for data in files.values {
            guard data.count <= Self.maximumFileBytes else { throw ConfigurationBackupError("Configuration file exceeds limit") }
            total += data.count
            guard total <= Self.maximumTotalBytes else { throw ConfigurationBackupError("Configuration backup exceeds limit") }
        }
        guard total <= Self.maximumTotalBytes else { throw ConfigurationBackupError("Configuration backup exceeds limit") }
        if let digests = m.digests {
            guard Set(digests.keys) == declared else { throw ConfigurationBackupError("Invalid configuration digests") }
            for (path, data) in files where digests[path] != Self.digest(data) {
                throw ConfigurationBackupError("Configuration content does not match manifest")
            }
        }
    }

    public func transportData() throws -> Data {
        try validate()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumTransportBytes else { throw ConfigurationBackupError("Configuration transport exceeds limit") }
        return data
    }

    public static func decodeTransport(_ data: Data) throws -> Self {
        guard data.count <= maximumTransportBytes else { throw ConfigurationBackupError("Configuration transport exceeds limit") }
        let snapshot = try PropertyListDecoder().decode(Self.self, from: data)
        try snapshot.validate()
        return snapshot
    }
}

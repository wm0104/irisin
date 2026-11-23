import Darwin
import Foundation
import IrisinProtocol

/// A folder grant independent of Downloads. There is deliberately no default path.
@MainActor
final class ConfigurationBackupDirectory {
    static let key = "configurationBackup.directory"
    private static let settings = Stored(key: key, defaultValue: Data())

    struct Access {
        var bookmark: (URL) throws -> Data = { try $0.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) }
        var resolve: (Data) throws -> (url: URL, stale: Bool) = { data in
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
            return (url, stale)
        }
        var start: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
        var stop: (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    }

    private nonisolated struct Identity: Codable, Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private nonisolated struct Selection: Codable {
        let id: UUID
        let bookmark: Data
        let identity: Identity
        var retentionAccepted: Bool
    }

    nonisolated enum Failure: LocalizedError {
        case selectFolder, unavailable, invalidFolder, changedFolder

        var errorDescription: String? {
            switch self {
            case .selectFolder: String(localized: "Choose a backup folder first.")
            case .unavailable: String(localized: "The backup folder permission has expired or is unavailable. Select the folder again.")
            case .invalidFolder: String(localized: "Choose an existing, writable local folder. Cloud folders and symbolic links are not supported.")
            case .changedFolder: String(localized: "The backup folder changed. Confirm the retention rule for this folder again.")
            }
        }
    }

    private let defaults: UserDefaults?
    private let access: Access

    init(defaults: UserDefaults? = nil, access: Access = Access()) {
        self.defaults = defaults
        self.access = access
    }

    private var storedSelection: Data? {
        if let defaults { return defaults.data(forKey: Self.key) }
        let data = Self.settings.wrappedValue
        return data.isEmpty ? nil : data
    }

    var hasSelection: Bool { storedSelection != nil }
    var selectionID: UUID? { try? selection().id }
    var retentionAccepted: Bool { (try? selection().retentionAccepted) == true }

    private func selection() throws -> Selection {
        guard let data = storedSelection else { throw Failure.selectFolder }
        do { return try JSONDecoder().decode(Selection.self, from: data) }
        catch { throw Failure.unavailable }
    }

    private func save(_ selection: Selection) throws {
        let data = try JSONEncoder().encode(selection)
        if let defaults { defaults.set(data, forKey: Self.key) }
        else { Self.settings.wrappedValue = data }
    }

    func select(_ url: URL) throws {
        let started = access.start(url)
        defer { if started { access.stop(url) } }
        let identity = try validate(url)
        let bookmark = try access.bookmark(url)
        let reopened = try access.resolve(bookmark)
        guard !reopened.stale else { throw Failure.unavailable }
        let reopenedStarted = access.start(reopened.url)
        defer { if reopenedStarted { access.stop(reopened.url) } }
        guard try validate(reopened.url) == identity else { throw Failure.changedFolder }
        // Publish only after the persisted grant can reopen the same filesystem node.
        try save(Selection(id: UUID(), bookmark: bookmark, identity: identity, retentionAccepted: false))
    }

    func acceptRetention(for id: UUID) throws {
        var current = try selection()
        guard current.id == id else { throw Failure.changedFolder }
        current.retentionAccepted = true
        try save(current)
    }

    func withAccess<T>(_ body: @MainActor (URL) async throws -> T) async throws -> T {
        let current = try selection()
        let resolved: (url: URL, stale: Bool)
        do { resolved = try access.resolve(current.bookmark) }
        catch { throw Failure.unavailable }
        guard !resolved.stale else { throw Failure.unavailable }
        let started = access.start(resolved.url)
        defer { if started { access.stop(resolved.url) } }
        guard try validate(resolved.url) == current.identity else { throw Failure.changedFolder }
        // Scope remains held across every suspension in list/create/restore.
        return try await body(resolved.url)
    }

    private func validate(_ url: URL) throws -> Identity {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
            throw Failure.invalidFolder
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isUbiquitousItemKey, .isWritableKey])
        } catch { throw Failure.unavailable }
        guard values.isDirectory == true, values.isSymbolicLink != true,
              values.isUbiquitousItem != true, values.isWritable == true,
              FileManager.default.isReadableFile(atPath: url.path),
              FileManager.default.isWritableFile(atPath: url.path)
        else { throw Failure.invalidFolder }
        // No probe file: validation must never delete an existing user's file.
        guard Self.isAllowedDataFolder(url.path, installRoots: installRoots) else { throw Failure.invalidFolder }
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Failure.unavailable }
        return Identity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    private var installRoots: [String] {
        var roots = [JailbreakRoot.prefix]
        if case let .daemon(root) = PrivilegedBackend.backend { roots.append(root) }
        return roots
    }

    /// Picker grants are for user data, never a bootstrap or a live configuration tree.
    static func isAllowedDataFolder(_ path: String, installRoots: [String]) -> Bool {
        func inside(_ value: String, _ root: String) -> Bool { value == root || value.hasPrefix(root + "/") }
        let raw = URL(fileURLWithPath: path).standardizedFileURL
        let canonical = raw.resolvingSymlinksInPath().path
        guard !(raw.pathComponents + URL(fileURLWithPath: canonical).pathComponents).contains(where: { $0.hasPrefix(".jbroot") }) else { return false }
        for root in installRoots {
            let resolvedRoot = URL(fileURLWithPath: root.isEmpty ? "/" : root).resolvingSymlinksInPath().path
            if resolvedRoot != "/", inside(canonical, resolvedRoot) { return false }
            // RootHide's var may be a link into a shared app-group outside the bootstrap.
            for relative in ConfigurationSnapshot.roots {
                let name = String(relative.split(separator: "/").last!)
                let suffix = relative.hasPrefix("config/") ? "/var/mobile/Library/" : "/etc/apt/"
                let source = URL(fileURLWithPath: root + suffix + name).resolvingSymlinksInPath().path
                if inside(canonical, source) { return false }
            }
        }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let userRoots = [
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("tmp"),
            URL(fileURLWithPath: "/var/mobile/Documents"),
            URL(fileURLWithPath: "/var/mobile/Containers"),
            FileManager.default.temporaryDirectory,
        ]
        return userRoots.contains { inside(canonical, $0.resolvingSymlinksInPath().path) }
    }
}

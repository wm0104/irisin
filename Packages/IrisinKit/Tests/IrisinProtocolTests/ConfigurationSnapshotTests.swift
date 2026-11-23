import Darwin
import Foundation
import IrisinProtocol
import XCTest

final class ConfigurationSnapshotTests: XCTestCase {
    private func snapshot() -> ConfigurationSnapshot {
        let metadata = ConfigurationSnapshot.Metadata(mode: 0o640, uid: getuid(), gid: getgid(), seconds: 100, nanoseconds: 20)
        return .init(manifest: .init(files: ["config/Preferences/value"], directories: ["config/Preferences"],
                                    metadata: ["config/Preferences": metadata, "config/Preferences/value": metadata]),
                     files: ["config/Preferences/value": Data("fixture".utf8)])
    }

    func testClosedJobsRoundTripWithoutPathsAndRejectEmptySelection() throws {
        for job in [InstallerJob.configurationBackup, .configurationRestore(preferences: true, sources: false),
                    .configurationRestore(preferences: false, sources: true)] {
            XCTAssertEqual(try InstallerJob.decode(job.encoded()), job)
            XCTAssertLessThan(try job.encoded().count, IrisinWire.maximumJobByteCount)
        }
        XCTAssertThrowsError(try InstallerJob.configurationRestore(preferences: false, sources: false).validate())
        XCTAssertEqual(try ConfigurationSnapshot.decodeTransport(snapshot().transportData()).files, snapshot().files)
    }

    func testTraversalUnlistedRetiredAndDeepPathsAreRejected() throws {
        for path in ["/config/Preferences/x", "config/Preferences/../x", "config//Preferences/x",
                     "config/Preferences/./x", "config/Preferences/x/", "config/Preferences/a\\b",
                     "config/Preferences/a\u{0}b", "config/Filza/x", "config/Preference/x", "dpkg/status"] {
            XCTAssertNil(ConfigurationSnapshot.root(for: path), path)
        }
        XCTAssertFalse(ConfigurationSnapshot.validPath(Array(repeating: "a", count: 33).joined(separator: "/")))
        var invalid = snapshot()
        invalid.manifest.files = ["config/Preferences/../../etc/passwd"]
        XCTAssertThrowsError(try invalid.validate())
    }

    func testManifestMembershipAndMetadataAreStrict() throws {
        var invalid = snapshot()
        invalid.manifest.metadata["config/Preferences/value"]!.mode = 0o4755
        XCTAssertThrowsError(try invalid.validate())
        invalid = snapshot()
        invalid.manifest.metadata["config/Preferences/value"]!.nanoseconds = 1_000_000_000
        XCTAssertThrowsError(try invalid.validate())
        invalid = snapshot()
        invalid.manifest.metadata.removeValue(forKey: "config/Preferences")
        XCTAssertThrowsError(try invalid.validate())
        invalid = snapshot()
        invalid.manifest.files.append("config/Preferences/value")
        XCTAssertThrowsError(try invalid.validate())
        invalid = snapshot()
        invalid.manifest.digests = ["config/Preferences/value": String(repeating: "0", count: 64)]
        XCTAssertThrowsError(try invalid.validate())
        invalid = snapshot()
        invalid.manifest.directories.append("config/Preferences/value")
        XCTAssertThrowsError(try invalid.validate())
    }

    func testFileTotalAndEntryLimits() throws {
        var invalid = snapshot()
        invalid.files["config/Preferences/value"] = Data(repeating: 0, count: ConfigurationSnapshot.maximumFileBytes + 1)
        XCTAssertThrowsError(try invalid.validate())
        let data = Data(repeating: 0, count: ConfigurationSnapshot.maximumFileBytes)
        invalid = snapshot()
        for index in 0 ..< 4 {
            let path = "config/Preferences/large-\(index)"
            invalid.files[path] = data
            invalid.manifest.files.append(path)
            invalid.manifest.metadata[path] = invalid.manifest.metadata["config/Preferences"]
        }
        XCTAssertThrowsError(try invalid.validate())
        invalid = snapshot()
        invalid.manifest.directories += (0 ..< ConfigurationSnapshot.maximumEntries).map { "config/Preferences/\($0)" }
        XCTAssertThrowsError(try invalid.validate())
    }

    func testDescriptorRejectsPipeReadOnlyAppendHardlinkAndOversize() throws {
        var ends: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&ends), 0)
        defer { close(ends[0]); close(ends[1]) }
        XCTAssertThrowsError(try InstallerJob.configurationBackup.validateConfigurationDescriptor(ends[1]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: url) }
        let readOnly = open(url.path, O_RDONLY)
        defer { close(readOnly) }
        XCTAssertThrowsError(try InstallerJob.configurationBackup.validateConfigurationDescriptor(readOnly))
        let descriptor = open(url.path, O_RDWR)
        defer { close(descriptor) }
        XCTAssertNoThrow(try InstallerJob.configurationBackup.validateConfigurationDescriptor(descriptor))
        XCTAssertThrowsError(try InstallerJob.configurationRestore(preferences: true, sources: false).validateConfigurationDescriptor(descriptor))
        let hardlink = url.appendingPathExtension("hardlink")
        XCTAssertEqual(link(url.path, hardlink.path), 0)
        XCTAssertThrowsError(try InstallerJob.configurationBackup.validateConfigurationDescriptor(descriptor))
        try FileManager.default.removeItem(at: hardlink)
        XCTAssertEqual(fcntl(descriptor, F_SETFL, O_APPEND), 0)
        XCTAssertThrowsError(try InstallerJob.configurationBackup.validateConfigurationDescriptor(descriptor))
        XCTAssertEqual(fcntl(descriptor, F_SETFL, 0), 0)
        XCTAssertEqual(ftruncate(descriptor, off_t(ConfigurationSnapshot.maximumTransportBytes + 1)), 0)
        XCTAssertThrowsError(try InstallerJob.configurationRestore(preferences: true, sources: false).validateConfigurationDescriptor(descriptor))
    }
}

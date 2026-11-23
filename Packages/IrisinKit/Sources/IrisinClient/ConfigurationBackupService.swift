import Darwin
import Foundation
import IrisinProtocol

public final class ConfigurationBackupService: Sendable {
    private let start: @Sendable (InstallerJob, Int32) async throws -> JobTranscript
    public init(link: DaemonLink) {
        start = { job, descriptor in try await link.run(job, descriptor: descriptor) }
    }

    /// A transport seam for native fixtures: tests still run the real helper runner.
    init(start: @escaping @Sendable (InstallerJob, Int32) async throws -> JobTranscript) {
        self.start = start
    }

    public func create(in directory: URL, allowPruning: Bool) async throws -> ConfigurationBackupRecord {
        let temporary = try temporaryDescriptor()
        defer { close(temporary) }
        let transcript = try await start(.configurationBackup, temporary)
        try await finished(transcript)
        let (data, _) = try ConfigurationDirectory.read(
            descriptor: temporary, limit: ConfigurationSnapshot.maximumTransportBytes, allowUnlinked: true
        )
        let snapshot = try ConfigurationSnapshot.decodeTransport(data)
        return try ConfigurationBackupStorage.publish(snapshot, in: directory, allowPruning: allowPruning)
    }

    public func restore(from backup: URL, preferences: Bool, sources: Bool) async throws {
        let job = InstallerJob.configurationRestore(preferences: preferences, sources: sources)
        try job.validate()
        let snapshot = try ConfigurationBackupStorage.load(from: backup)
        let descriptor = try temporaryDescriptor()
        defer { close(descriptor) }
        try ConfigurationDirectory.write(descriptor: descriptor, data: snapshot.transportData())
        let transcript = try await start(job, descriptor)
        try await finished(transcript)
    }

    private func temporaryDescriptor() throws -> Int32 {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("irisin-config-XXXXXX").path
        var template = Array(path.utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw ConfigurationDirectory.failure() }
        // The file has no persistent pathname and cannot become a saved backup.
        let removed = template.withUnsafeBufferPointer { unlink($0.baseAddress!) }
        guard removed == 0 else {
            let error = ConfigurationDirectory.failure(); close(fd); throw error
        }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            let error = ConfigurationDirectory.failure(); close(fd); throw error
        }
        return fd
    }

    private func finished(_ transcript: JobTranscript) async throws {
        var status: Int32?
        var failure: String?
        for await event in transcript.events {
            switch event {
            case let .exit(code): status = code
            case let .failure(.installationStopped(detail)): failure = detail
            case let .failure(problem): failure = problem.description
            default: break
            }
        }
        guard status == 0 else {
            throw ConfigurationBackupError(failure ?? "Configuration helper did not complete successfully")
        }
    }
}

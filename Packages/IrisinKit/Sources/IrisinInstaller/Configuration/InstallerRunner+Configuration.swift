import Darwin
import Foundation
import IrisinProtocol

extension InstallerRunner {
    func runConfiguration(_ job: InstallerJob) -> Int32 {
        do {
            try job.validateConfigurationDescriptor(configurationDescriptor)
            let engine = ConfigurationBackupEngine(root: installRoot, layout: layout)
            switch job {
            case .configurationBackup:
                emit(.phase(.applying))
                let data = try engine.capture().transportData()
                try ConfigurationDirectory.write(descriptor: configurationDescriptor, data: data)
                guard fsync(configurationDescriptor) == 0 else { throw ConfigurationDirectory.failure() }
            case let .configurationRestore(preferences, sources):
                let (data, _) = try ConfigurationDirectory.read(
                    descriptor: configurationDescriptor, limit: ConfigurationSnapshot.maximumTransportBytes,
                    allowUnlinked: true
                )
                let snapshot = try ConfigurationSnapshot.decodeTransport(data)
                emit(.phase(.applying))
                try engine.restore(snapshot, preferences: preferences, sources: sources)
            default:
                throw IrisinFailure(code: .invalidRequest)
            }
            return 0
        } catch {
            // Only our fixed-scope error prose, never file contents or user paths.
            let detail = (error as? ConfigurationBackupError)?.detail ?? "Configuration operation failed"
            emit(.failure(.installationStopped(detail: detail)))
            return 1
        }
    }
}

import Darwin
import Foundation

public extension InstallerJob {
    var isConfigurationJob: Bool {
        switch self {
        case .configurationBackup, .configurationRestore: true
        default: false
        }
    }

    /// Rechecked by daemon, helper, and simulator. A regular anonymous or
    /// single-link file, with the right access and bounded size; never a pipe or log.
    func validateConfigurationDescriptor(_ descriptor: Int32) throws {
        guard isConfigurationJob else { return }
        var info = stat()
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_nlink <= 1,
              flags & O_APPEND == 0, info.st_size >= 0,
              info.st_size <= ConfigurationSnapshot.maximumTransportBytes else {
            throw IrisinFailure(code: .invalidRequest)
        }
        let access = flags & O_ACCMODE
        switch self {
        case .configurationBackup:
            guard access == O_WRONLY || access == O_RDWR, info.st_size == 0 else {
                throw IrisinFailure(code: .invalidRequest)
            }
        case .configurationRestore:
            guard access == O_RDONLY || access == O_RDWR, info.st_size > 0 else {
                throw IrisinFailure(code: .invalidRequest)
            }
        default: break
        }
    }
}

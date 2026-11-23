import AptRepository
import Foundation

extension Downloads {
    /// Waits until every one of these packages is on disk, or answers the
    /// first download's failure. Stops when `plan` is no longer the queue's.
    /// The queue page and a browser's confirmed plan both wait here.
    func awaitFiles(
        of packages: [Package],
        in plan: UUID,
        onTransfer: (@MainActor () -> Void)? = nil,
        progress: @MainActor () -> Void = {}
    ) async -> String? {
        let urls = packages.map { $0.obtainDownloadLink() }
        var sawTransfer = false
        // ponytail: polls the statuses four times a second; a publisher on
        // the statuses if the tick ever shows
        while !Task.isCancelled, PackageQueue.shared.plan?.id == plan {
            let statuses = urls.map { (status: status(for: $0), running: isDownloading($0)) }
            if let onTransfer, !sawTransfer, urls.contains(where: { hasStartedTransfer(for: $0) }) {
                sawTransfer = true
                onTransfer()
            }
            // a retry's download keeps the old error until it first reports
            if let failed = statuses.first(where: {
                $0.status?.errorDescription != nil && !$0.running
            })?.status?.errorDescription {
                return failed
            }
            // A shortcut must wait out cache verification; a previous
            // attempt can still be reporting a file while it is checked.
            if statuses.allSatisfy({ $0.status?.file != nil && (onTransfer == nil || !$0.running) }) {
                return nil
            }
            // the queue starts every download it needs; one that is neither
            // done nor running was stopped from outside
            if statuses.contains(where: { $0.status?.file == nil && !$0.running }) {
                return String(localized: "The download was interrupted.")
            }
            progress()
            try? await Task.sleep(continuousSeconds: 0.25)
        }
        return nil
    }
}

import AptRepository
import Foundation

/// A shortcut grants execution only to the preview the user tapped,
/// never to a replacement proposal or a queue-only confirmation.
enum QueueConfirmation {
    enum VersionChange {
        case update, downgrade, reinstall

        func matches(target: String, installed: String) -> Bool {
            switch (self, Package.compareVersion(target, b: installed)) {
            case (.update, .aIsBiggerThenB), (.downgrade, .aIsSmallerThenB), (.reinstall, .aIsEqualToB): true
            default: false
            }
        }
    }

    enum Shortcut {
        case install(String)
        case versionChange(VersionChange, String)
        case batchUpdate
        case remove(String)

        var title: String {
            switch self {
            case .install: String(localized: "Confirm and Install")
            case .versionChange(.update, _), .batchUpdate: String(localized: "Confirm and Update")
            case .versionChange(.downgrade, _): String(localized: "Confirm and Downgrade")
            case .versionChange(.reinstall, _): String(localized: "Confirm and Reinstall")
            case .remove: String(localized: "Confirm and Remove")
            }
        }
    }

    case queueOnly
    case execute(UUID)

    func accepts(plan: UUID?) -> Bool {
        switch self {
        case .queueOnly: true
        case let .execute(shown): shown == plan
        }
    }

    var executionIntent: QuickOperationIntent? {
        guard case let .execute(plan) = self else { return nil }
        return QuickOperationIntent(plan: plan)
    }

    static func offersRemoval(
        requested: String, queueIsEmpty: Bool, isPlainRemoval: Bool,
        installsPackages: Bool, removals: [String], offersCleanup: Bool
    ) -> Bool {
        queueIsEmpty && isPlainRemoval && !installsPackages && removals == [requested] && !offersCleanup
    }

    static func offersVersionChange(
        _ change: VersionChange, requested: String, queueIsEmpty: Bool, isPlainChange: Bool, installs: [String],
        installedVersion: String?, targetVersion: String?, origin: URL?, targetRepository: URL?, localArchive: Bool = false
    ) -> Bool {
        guard queueIsEmpty, isPlainChange, installs == [requested], let installedVersion, let targetVersion else { return false }
        return matchesVersionChange(
            change, installedVersion: installedVersion, targetVersion: targetVersion,
            origin: origin, targetRepository: targetRepository, localArchive: localArchive
        )
    }

    static func matchesVersionChange(
        _ change: VersionChange, installedVersion: String, targetVersion: String,
        origin: URL?, targetRepository: URL?, localArchive: Bool = false
    ) -> Bool {
        // A file the user opened is an explicit choice rather than a move
        // between repositories. Repository records still need a known origin.
        let sameSource = if localArchive { targetRepository == nil } else { origin != nil && origin == targetRepository }
        return sameSource && change.matches(target: targetVersion, installed: installedVersion)
    }

    static func offersInstall(
        requested: String?, queueIsEmpty: Bool, isPlainInstall: Bool,
        installs: Set<String>, requiredBy: [String: [String]]
    ) -> Bool {
        guard let requested, queueIsEmpty, isPlainInstall, installs.contains(requested) else { return false }
        // Walk hard dependencies outward from the request. Unrelated repairs,
        // recommendations and isolated cycles are not part of this shortcut.
        var dependencies: [String: [String]] = [:]
        for (dependency, parents) in requiredBy where installs.contains(dependency) {
            for parent in parents {
                dependencies[parent, default: []].append(dependency)
            }
        }
        var seen: Set = [requested]
        var pending = [requested]
        while let parent = pending.popLast() {
            for dependency in dependencies[parent, default: []] where seen.insert(dependency).inserted {
                pending.append(dependency)
            }
        }
        return seen == installs
    }
}

final class QuickOperationIntent {
    enum Stop: CaseIterable {
        case planChanged, leftQueue, cancelled, downloadFailed
    }

    let plan: UUID
    private(set) var waitsOnQueue = false
    private(set) var stopped: Stop?

    init(plan: UUID) {
        self.plan = plan
    }

    func waitOnQueue() {
        waitsOnQueue = true
    }

    func stop(_ reason: Stop) {
        stopped = reason
    }

    func canContinue(plan current: UUID?, blocked: Bool, queueVisible: Bool) -> Bool {
        canStart(plan: current, blocked: blocked) && (!waitsOnQueue || queueVisible)
    }

    /// Also used at the end of the progress sheet's presentation animation,
    /// immediately before the installer begins on the main actor.
    func canStart(plan current: UUID?, blocked: Bool) -> Bool {
        stopped == nil && plan == current && !blocked
    }
}

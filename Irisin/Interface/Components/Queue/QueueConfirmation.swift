import AptRepository
import AptResolver
import Foundation
import IrisinProtocol

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

/// An already queued plan may use the existing quick-operation path only
/// when its entire transaction is the one simple request the user queued.
extension QueueConfirmation {
    static func offersQueuedExecution(_ queue: PackageQueue) -> Bool {
        guard let plan = queue.plan, queue.blocked == nil, queue.cleanup.isEmpty,
              queue.notices.isEmpty, plan.heldBack.isEmpty, plan.diagnostics.isEmpty,
              plan.migration == nil, !plan.recoveryMode, !plan.repairsInstalledSet,
              QueueInstallChecks.hasDpkg(plan), !queue.actions.isEmpty
        else { return false }
        if QueueChangeController.isPlainBatchUpdate(plan, actions: queue.actions) { return true }
        guard queue.actions.count == 1, let action = queue.actions.first else { return false }
        switch action {
        case let .install(requested):
            let identity = requested.identity
            guard plan.install.contains(requested), plan.remove.isEmpty else { return false }
            if let installed = plan.snapshot.installed.first(where: { $0.identity == identity }) {
                guard plan.install.count == 1, plan.install.first == requested,
                      QueueChangeController.canReplaceInstalledPackage(installed, with: requested),
                      plan.stages == [.unpack([identity]), .configure([identity])],
                      let installedVersion = installed.latestVersion, let targetVersion = requested.latestVersion
                else { return false }
                let change: VersionChange? = switch Package.compareVersion(targetVersion, b: installedVersion) {
                case .aIsBiggerThenB: .update
                case .aIsSmallerThenB: .downgrade
                case .aIsEqualToB: .reinstall
                case .invalidParameter: nil
                }
                guard let change else { return false }
                return matchesVersionChange(
                    change, installedVersion: installedVersion, targetVersion: targetVersion,
                    origin: plan.snapshot.origins[identity], targetRepository: requested.repoRef,
                    localArchive: requested.localFileURL != nil
                )
            }
            let installs = Set(plan.install.map(\.identity))
            let plain = installs.isDisjoint(with: plan.snapshot.installed.map(\.identity))
                && plan.install.allSatisfy { $0 == requested || $0.localFileURL == nil }
                && plan.stages.allSatisfy { stage in
                    if case .remove = stage { return false }
                    return Set(stage.identities).isSubset(of: installs)
                }
            return offersInstall(
                requested: identity, queueIsEmpty: true, isPlainInstall: plain,
                installs: installs, requiredBy: plan.requiredBy
            )
        case let .remove(identity):
            let protected = plan.remove.contains { package in
                let fields = package.latestMetadata ?? [:]
                return fields["essential"] == "yes" || fields["protected"] == "yes"
                    || ["apt", "dpkg", "essential", "firmware", "bash", "coreutils",
                        "base", "base-files", "base-passwd", "libroot", "roothide"].contains(package.identity)
            }
            return offersRemoval(
                requested: identity, queueIsEmpty: true,
                isPlainRemoval: !identity.hasPrefix(InstallerJob.selfIdentityPrefix)
                    && !protected && plan.stages == [.remove([identity])],
                installsPackages: !plan.install.isEmpty, removals: plan.remove.map(\.identity),
                offersCleanup: !plan.unneeded.isEmpty
            )
        }
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

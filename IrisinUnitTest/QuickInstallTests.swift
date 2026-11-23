import AptRepository
import AptResolver
import Foundation
import Testing
import UIKit
@testable import irisin

@MainActor
struct QuickInstallTests {
    @Test func onlyOrdinaryFreshInstallsWithRequiredDependenciesOfferTheShortcut() {
        let dependencies = ["library": ["app"], "base": ["library"]]
        func offers(
            _ requested: String? = "app", empty: Bool = true, safe: Bool = true,
            installs: Set<String> = ["app", "library", "base"], requiredBy: [String: [String]]? = nil
        ) -> Bool {
            QueueConfirmation.offersInstall(
                requested: requested, queueIsEmpty: empty, isPlainInstall: safe,
                installs: installs, requiredBy: requiredBy ?? dependencies
            )
        }
        #expect(offers())
        #expect(offers(installs: ["app"]))
        #expect(!offers(nil))
        #expect(!offers(empty: false))
        #expect(!offers(safe: false))
        #expect(!offers(installs: ["library", "base"]))
        #expect(!offers(installs: ["app", "library", "base", "repair"]))
        #expect(!offers(requiredBy: ["library": ["base"], "base": ["library"]]))
    }

    @Test func onlyAnIsolatedRemovalWithNoCleanupChoiceOffersTheShortcut() {
        func offers(
            installed: Bool = false, removed: [String] = ["target"], cleanup: Bool = false,
            empty: Bool = true, safe: Bool = true
        ) -> Bool {
            QueueConfirmation.offersRemoval(
                requested: "target", queueIsEmpty: empty, isPlainRemoval: safe,
                installsPackages: installed, removals: removed, offersCleanup: cleanup
            )
        }
        #expect(offers())
        #expect(!offers(installed: true))
        #expect(!offers(removed: ["target", "dependent"]))
        #expect(!offers(removed: ["other"]))
        #expect(!offers(cleanup: true))
        #expect(!offers(empty: false))
        #expect(!offers(safe: false))
    }

    @Test func onlyAnIsolatedVersionChangeFromItsKnownInstallOriginOffersTheShortcut() throws {
        let source = try #require(URL(string: "https://source.example/"))
        let otherSource = try #require(URL(string: "https://other.example/"))
        func offers(
            _ change: QueueConfirmation.VersionChange, version: String, installedVersion: String? = "1.6.34",
            hasOrigin: Bool = true, sameSource: Bool = true, empty: Bool = true,
            plain: Bool = true, installs: [String] = ["target"]
        ) -> Bool {
            QueueConfirmation.offersVersionChange(
                change, requested: "target", queueIsEmpty: empty, isPlainChange: plain, installs: installs,
                installedVersion: installedVersion, targetVersion: version,
                origin: hasOrigin ? source : nil, targetRepository: sameSource ? source : otherSource
            )
        }
        #expect(!offers(.update, version: "1.6.33"))
        #expect(!offers(.downgrade, version: "1.6.35"))
        let changes: [(QueueConfirmation.VersionChange, String)] = [
            (.update, "1.6.35"), (.downgrade, "1.6.33"), (.reinstall, "1.6.34-0"),
        ]
        for (change, target) in changes {
            #expect(offers(change, version: target))
            #expect(!offers(change, version: target, installedVersion: nil))
            #expect(!offers(change, version: change == .reinstall ? "1.6.35" : "1.6.34"))
            #expect(!offers(change, version: target, hasOrigin: false))
            #expect(!offers(change, version: target, sameSource: false))
            #expect(!offers(change, version: target, empty: false))
            #expect(!offers(change, version: target, plain: false))
            #expect(!offers(change, version: target, installs: ["target", "dependency"]))
        }
    }

    @Test func anExplicitLocalArchiveCanReinstallTheSameDebianVersionWithoutAnOrigin() {
        func offers(_ version: String, isArchive: Bool = true, plain: Bool = true) -> Bool {
            QueueConfirmation.offersVersionChange(
                .reinstall, requested: "target", queueIsEmpty: true, isPlainChange: plain, installs: ["target"],
                installedVersion: "4.0.3", targetVersion: version, origin: nil, targetRepository: nil, localArchive: isArchive
            )
        }
        #expect(offers("4.0.3-0"))
        #expect(!offers("4.0.2"))
        #expect(!offers("4.0.3", isArchive: false))
        #expect(!offers("4.0.3", plain: false))
    }

    @Test func batchShortcutOnlyCoversTheRequestedSameSourceUpgrades() throws {
        let source = try #require(URL(string: "https://source.example/"))
        let first = Package(identity: "first", payload: ["2": ["filename": "first.deb"]], repoRef: source)
        let second = Package(identity: "second", payload: ["2": ["filename": "second.deb"]], repoRef: source)
        let installed = [first, second].map {
            Package(identity: $0.identity, payload: ["1": ["status": "install ok installed"]])
        }
        let actions: [ResolutionAction] = [.install(first), .install(second)]
        func solve(origins: [String: URL]) throws -> ResolutionPlan {
            try PackageResolver.resolve(
                request: .init(actions: actions),
                snapshot: .init(packages: [first, second], installed: installed, architecture: "iphoneos-arm64e", origins: origins)
            )
        }
        let ordinary = try solve(origins: [first.identity: source, second.identity: source])
        let unknownOrigin = try solve(origins: [first.identity: source])
        #expect(QueueChangeController.isPlainBatchUpdate(ordinary, actions: actions))
        #expect(!QueueChangeController.isPlainBatchUpdate(ordinary, actions: [.install(first)]))
        #expect(!QueueChangeController.isPlainBatchUpdate(unknownOrigin, actions: actions))
        let differentArchive = Package(identity: first.identity, payload: ["2": ["filename": "different.deb"]], repoRef: source)
        #expect(!QueueChangeController.isPlainBatchUpdate(ordinary, actions: [.install(differentArchive), .install(second)]))
    }

    @Test func reinstallingAnUnfinishedPackageKeepsOrdinaryConfirmation() {
        let archive = Package(identity: "target", payload: ["1": [:]])
        func installed(_ status: String) -> Package {
            Package(identity: "target", payload: ["1": ["status": status]])
        }
        #expect(QueueChangeController.canReplaceInstalledPackage(installed("install ok installed"), with: archive))
        #expect(!QueueChangeController.canReplaceInstalledPackage(installed("install reinstreq half-installed"), with: archive))
        #expect(!QueueChangeController.canReplaceInstalledPackage(installed("install ok unpacked"), with: archive))
    }

    @Test func queueOnlyNeverAuthorizesExecutionAndAnOlderPreviewCannotAuthorizeANewPlan() {
        let shown = UUID()
        #expect(QueueConfirmation.queueOnly.accepts(plan: shown))
        #expect(QueueConfirmation.queueOnly.executionIntent == nil)
        #expect(QueueConfirmation.execute(shown).accepts(plan: shown))
        #expect(!QueueConfirmation.execute(shown).accepts(plan: UUID()))
        #expect(!QueueConfirmation.execute(shown).accepts(plan: nil))
    }

    @Test func filesOnDiskCanContinueWithoutOpeningQueueButWaitingNeedsTheVisibleQueue() throws {
        let shown = UUID()
        let install = try #require(QueueConfirmation.execute(shown).executionIntent)
        #expect(install.canContinue(plan: shown, blocked: false, queueVisible: false))
        install.waitOnQueue()
        #expect(install.canContinue(plan: shown, blocked: false, queueVisible: true))
        #expect(!install.canContinue(plan: shown, blocked: false, queueVisible: false))
        #expect(!install.canContinue(plan: UUID(), blocked: false, queueVisible: true))
    }

    @Test func progressPresentationCannotStartIfTheConfirmedPlanChangedOrBecameBlocked() throws {
        let shown = UUID()
        let install = try #require(QueueConfirmation.execute(shown).executionIntent)
        #expect(install.canStart(plan: shown, blocked: false))
        #expect(!install.canStart(plan: shown, blocked: true))
        #expect(!install.canStart(plan: UUID(), blocked: false))
        #expect(!install.canStart(plan: nil, blocked: false))
    }

    @Test func cancellationOrFailureCannotBeResumedByRetry() throws {
        let shown = UUID()
        for reason in QuickOperationIntent.Stop.allCases {
            let install = try #require(QueueConfirmation.execute(shown).executionIntent)
            install.waitOnQueue()
            install.stop(reason)
            #expect(!install.canContinue(plan: shown, blocked: false, queueVisible: true))
        }
    }
}

extension QuickInstallTests {
    /// Capture UIKit's real presentation boundary, not a duplicate alert policy.
    private final class FailurePresenter: UIViewController {
        var alerts: [UIViewController] = []

        override func present(_ controller: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
            alerts.append(controller)
            completion?()
        }
    }

    @Test(arguments: [
        "archive preparation failed: original reason",
        "",
        "Another operation is already running. Wait for it to finish, then try again.",
    ])
    func originalPageStagingFailurePresentsExistingConfirmationWithQueueExit(report: String) async throws {
        try await QueueFixtureGate.withLock {
            let queue = QueueController()
            let source = FailurePresenter()
            let id = UUID()
            let intent = try #require(QueueConfirmation.execute(id).executionIntent)
            intent.stop(.cancelled)
            queue.reportStagingFailure(report, from: source, shortcut: intent, plan: id)
            #expect(source.alerts.count == 1)
            let alert = try #require(source.alerts.first)
            #expect(String(describing: type(of: alert)).contains("AlertViewController"))
            alert.loadViewIfNeeded()
            let texts = alertTexts(in: alert.view)
            let reason = report.isEmpty ? String(localized: "Unable to prepare this operation. Try again.") : report
            #expect(texts.contains(reason))
            #expect(texts.contains(String(localized: "Open Queue")))
            #expect(texts.contains(String(localized: "Cancel")))
            #expect(!intent.canContinue(plan: id, blocked: false, queueVisible: false))
        }
    }

    @Test
    func aDedicatedStagingReportPresentsOnlyItsExistingNotice() async throws {
        try await QueueFixtureGate.withLock {
            let source = FailurePresenter()
            let id = UUID()
            let intent = try #require(QueueConfirmation.execute(id).executionIntent)
            QueueController().reportStagingFailure(
                "original detailed report", alertTitle: String(localized: "Download Failed"),
                from: source, shortcut: intent, plan: id
            )
            #expect(source.alerts.count == 1)
            let alert = try #require(source.alerts.first)
            alert.loadViewIfNeeded()
            let texts = alertTexts(in: alert.view)
            #expect(texts.contains("original detailed report"))
            #expect(texts.contains(String(localized: "Download Failed")))
            #expect(!texts.contains(String(localized: "Open Queue")))
        }
    }

    @Test(arguments: ["visibleQueue", "waitingOnQueue", "ordinaryQueue", "departedSource"])
    func stagingFailureDoesNotAddAPopupToExistingQueueOrAnAbsentSource(mode: String) async throws {
        try await QueueFixtureGate.withLock {
            let queue = QueueController()
            let source = FailurePresenter()
            let id = UUID()
            let intent = try #require(QueueConfirmation.execute(id).executionIntent)
            if mode == "visibleQueue" { queue.viewDidAppear(false) }
            if mode == "waitingOnQueue" { intent.waitOnQueue() }
            queue.reportStagingFailure(
                "original report", from: mode == "departedSource" ? nil : source,
                shortcut: mode == "ordinaryQueue" ? nil : intent, plan: id
            )
            #expect(source.alerts.isEmpty)
        }
    }

    private func alertTexts(in view: UIView) -> [String] {
        var texts = [view.accessibilityLabel].compactMap { $0 }
        if let label = view as? UILabel, let text = label.text { texts.append(text) }
        if let textView = view as? UITextView, let text = textView.text { texts.append(text) }
        for subview in view.subviews { texts += alertTexts(in: subview) }
        return texts
    }
}

extension QuickInstallTests {
    private final class StagingHost: InterfaceHostController {
        var queueSelections = 0
        override func selectQueue() { queueSelections += 1 }
        override func viewDidAppear(_: Bool) {}
        override func viewWillLayoutSubviews() {}
    }

    @Test(arguments: ["current", "staleBeforeFinish", "staleAfterPrompt", "noWindowBeforeFinish", "noWindowAfterPrompt"])
    func actualStagingCompletionAndOpenQueueRespectSourceAndPlan(mode: String) async throws {
        try await QueueFixtureGate.withLock {
            let manager = PackageQueue.shared
            try #require(manager.actions.isEmpty && manager.plan == nil)
            let report = PackageActionReport.shared
            report.clear()
            defer { manager.clear(); report.clear() }
            let package = Package(identity: "test.staging-boundary", payload: ["1.0": [
                "architecture": "all", "status": "install ok installed",
            ]])
            let snapshot = ResolutionSnapshot(packages: [], installed: [package], architecture: "arm64")
            let plan = try ResolutionPlan.recoveryRemoval(of: package.identity, in: snapshot, allowSystemRemoval: false)
            try #require(manager.commit(.init(actions: [.remove(package.identity)], cleanup: [], plan: plan,
                                             notices: [], revision: manager.revision)))
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let window = UIWindow(windowScene: try #require(scenes.first))
            let host = StagingHost()
            let source = UIViewController()
            host.addChild(source)
            host.view.addSubview(source.view)
            source.view.frame = host.view.bounds
            source.didMove(toParent: host)
            window.rootViewController = host
            window.isHidden = false
            window.layoutIfNeeded()
            defer { window.isHidden = true; window.rootViewController = nil }
            let intent = QuickOperationIntent(plan: plan.id)
            report.record("actual asynchronous preparation report")
            if mode == "staleBeforeFinish" { manager.clear() }
            if mode == "noWindowBeforeFinish" { source.view.removeFromSuperview() }
            // This is the production boundary called immediately after createOperationPayload awaits.
            QueueController().finishStaging(nil, plan: plan.id, shortcut: intent, failureSource: source)
            #expect(intent.stopped != nil)
            #expect(!intent.canStart(plan: plan.id, blocked: false))
            if mode == "noWindowBeforeFinish" {
                #expect(source.presentedViewController == nil)
                #expect(host.queueSelections == 0)
                return
            }
            try await waitForStagingUI { source.presentedViewController != nil }
            let alert = try #require(source.presentedViewController)
            alert.loadViewIfNeeded()
            #expect(alertTexts(in: alert.view).contains("actual asynchronous preparation report"))
            let button = try #require(openQueueButton(in: alert.view))
            // Wait for presentation before the real button dismisses its confirmation.
            try await Task.sleep(nanoseconds: 400_000_000)
            if mode == "staleAfterPrompt" { manager.clear() }
            if mode == "noWindowAfterPrompt" { source.view.removeFromSuperview() }
            button.sendActions(for: .touchUpInside)
            try await waitForStagingUI { source.presentedViewController == nil }
            #expect(host.queueSelections == (mode == "current" ? 1 : 0))
            #expect(!intent.canStart(plan: plan.id, blocked: false))
        }
    }

    private func openQueueButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton,
           alertTexts(in: button).contains(String(localized: "Open Queue")) { return button }
        return view.subviews.lazy.compactMap { openQueueButton(in: $0) }.first
    }

    private func waitForStagingUI(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(condition())
    }
}

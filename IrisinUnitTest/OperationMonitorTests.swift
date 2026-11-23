import AptRepository
import AptResolver
import Combine
@testable import irisin
import IrisinProtocol
import UIKit
import XCTest

final class OperationMonitorTests: XCTestCase {
    @MainActor
    private func monitor(removing identity: String = "test.old") throws -> OperationMonitor {
        let plan = try PackageResolver.resolve(
            request: .init(actions: [.remove(identity)]),
            snapshot: .init(
                packages: [],
                installed: [Package(identity: identity, payload: ["1": ["architecture": "all"]])],
                architecture: "iphoneos-arm64"
            )
        )
        return OperationMonitor(operation: .init(plan: plan, transaction: .init(install: [], remove: [identity])))
    }

    @MainActor
    func testRunningTitleDistinguishesRemovalFromInstallAndMixedOperations() throws {
        let removal = OperationController(operation: try monitor().operation)
        removal.loadViewIfNeeded()
        XCTAssertEqual(removal.title, String(localized: "Removing…"))

        let package = Package(identity: "test.new", payload: ["1": [
            "architecture": "all", "filename": "file:///test.new.deb",
        ]])
        let installed = Package(identity: "test.old", payload: ["1": ["architecture": "all"]])
        for removesPackage in [false, true] {
            let actions: [ResolutionAction] = removesPackage
                ? [.install(package), .remove(installed.identity)]
                : [.install(package)]
            let plan = try PackageResolver.resolve(
                request: .init(actions: actions),
                snapshot: .init(packages: [], installed: [installed], architecture: "iphoneos-arm64")
            )
            let controller = OperationController(operation: .init(
                plan: plan,
                transaction: .init(
                    install: [.init(identity: package.identity, path: "/test.new.deb")],
                    remove: plan.remove.map(\.identity)
                )
            ))
            controller.loadViewIfNeeded()
            XCTAssertEqual(controller.title, String(localized: "Installing"), "removesPackage: \(removesPackage)")
        }
    }

    @MainActor
    func testRemovingWhileConfiguringAnExistingPackageKeepsTheInstallingTitle() throws {
        let installed = Package(identity: "test.old", payload: ["1": ["architecture": "all"]])
        let pending = Package(identity: "test.pending", payload: ["1": [
            "architecture": "all", "status": "install ok unpacked",
        ]])
        let plan = try PackageResolver.resolve(
            request: .init(actions: [.remove(installed.identity)]),
            snapshot: .init(packages: [], installed: [installed, pending], architecture: "iphoneos-arm64")
        )
        XCTAssertTrue(plan.install.isEmpty)
        XCTAssertEqual(plan.stages, [.remove([installed.identity]), .configure([pending.identity])])
        let controller = OperationController(operation: .init(
            plan: plan,
            transaction: .init(
                install: [], remove: [installed.identity], stages: plan.stages, configureExisting: [pending.identity]
            )
        ))
        controller.loadViewIfNeeded()
        XCTAssertEqual(controller.title, String(localized: "Installing"))
    }

    /// Events become rows, a phase, a progress count and a warning list; the
    /// summary is the last row and the outcome is published after it.
    @MainActor
    func testEventsPopulatePublishedState() async throws {
        let monitor = try monitor()
        var outcomes: [OperationMonitor.Outcome] = []
        var lineCountsAtOutcome: [Int] = []
        let subscription = monitor.$outcome.compactMap(\.self).sink { outcome in
            outcomes.append(outcome)
            lineCountsAtOutcome.append(monitor.lines.count)
        }
        defer { subscription.cancel() }

        monitor.append("Ready")
        monitor.record(.phase(.applying))
        monitor.record(.progress(completed: 0, total: 2))
        monitor.record(.package(.removing, identity: "test.old", version: "1"))
        monitor.record(.script(identity: "test.old", member: "prerm", arguments: ["remove"]))
        monitor.record(.output("bye"))
        monitor.record(.progress(completed: 1, total: 2))
        monitor.record(.warning(.noProcess(name: "sharingd")))
        monitor.record(.warning(.noProcess(name: "sharingd")))
        monitor.finish(.succeeded)
        monitor.finish(.failed("ignored"))

        XCTAssertEqual(monitor.phase, .applying)
        XCTAssertEqual(monitor.progress, .init(completed: 1, total: 2))
        let warning = InstallerEvent.Problem.noProcess(name: "sharingd").localizedDescription
        XCTAssertEqual(monitor.warnings, [warning, warning])
        XCTAssertEqual(monitor.transcript.count, 8)
        XCTAssertEqual(monitor.lines, [
            "Ready",
            InstallerEvent.Phase.applying.localizedTitle,
            String(localized: "Removing \("test.old (1)")"),
            String(localized: "Running \("test.old.prerm remove")"),
            "bye",
            "[!] " + warning,
            "[!] " + warning,
            String(localized: "Operation completed."),
        ])
        XCTAssertEqual(outcomes, [.succeeded])
        XCTAssertEqual(lineCountsAtOutcome, [monitor.lines.count])
        let finished = await monitor.finished
        XCTAssertEqual(finished, .succeeded)
    }

    @MainActor
    func testProgressFractionAndFailureSummary() throws {
        XCTAssertEqual(OperationMonitor.Progress(completed: 0, total: 0).fraction, 0)
        XCTAssertEqual(OperationMonitor.Progress(completed: 3, total: 4).fraction, 0.75)
        let monitor = try monitor()
        monitor.finish(.failed("nope"))
        XCTAssertEqual(monitor.lines, ["nope"])
        XCTAssertFalse(monitor.outcome?.succeeded ?? true)
    }

    /// A retry that only repairs dpkg state has stages but no package diff;
    /// its running and completed pages still carry a visible status row.
    @MainActor
    func testMaintenanceRowForRecoveryWithoutPackageChanges() {
        XCTAssertTrue(OperationController.showsMaintenanceRow(changeCount: 0, outcome: nil))
        XCTAssertTrue(OperationController.showsMaintenanceRow(changeCount: 0, outcome: .succeeded))
        XCTAssertFalse(OperationController.showsMaintenanceRow(changeCount: 0, outcome: .failed("postrm failed")))
        XCTAssertFalse(OperationController.showsMaintenanceRow(changeCount: 1, outcome: nil))
    }

    /// The button closes the page, reloads the home screen when the tweaks
    /// changed, failed run or not, and leaves for an update of the app
    /// whatever the tweaks did.
    @MainActor
    func testEndingFollowsTweaksUnlessTheAppLeaves() throws {
        let unchanged = try monitor()
        unchanged.finish(.succeeded)
        XCTAssertEqual(unchanged.ending, .close)

        let changed = try monitor()
        changed.finish(.succeeded, changedTweaks: true)
        XCTAssertEqual(changed.ending, .reloadHomeScreen)

        let failed = try monitor()
        failed.finish(.failed("postinst failed"), changedTweaks: true)
        XCTAssertEqual(failed.ending, .reloadHomeScreen)

        let leaving = try monitor(removing: InstallerJob.selfIdentityPrefix + "test")
        leaving.finish(.succeeded, changedTweaks: true)
        XCTAssertEqual(leaving.ending, .updateApp)
    }

    @MainActor
    func testSkipClosesTheWholeResultSheetWithoutReloadingOrChangingTheOutcome() async throws {
        let runs: [(OperationMonitor.Outcome, Bool)] = [
            (.succeeded, true),
            (.failed("postrm failed"), true),
            (.failed("postrm failed"), false),
        ]
        for (outcome, changedHere) in runs {
            try await withResultSheet(
                monitor: monitor(),
                outcome: outcome,
                changedTweaks: changedHere,
                followsTweakChange: !changedHere,
                pushed: !changedHere
            ) { presenter, page, monitor in
                XCTAssertEqual(page.title, outcome.succeeded ? String(localized: "Completed") : String(localized: "Failed"))
                let reload = try XCTUnwrap(page.navigationItem.rightBarButtonItem)
                XCTAssertEqual(reload.title, String(localized: "Reload Home Screen"))
                let alternate = try XCTUnwrap(reload.menu?.children.first as? UIAction)
                XCTAssertEqual(alternate.title, String(localized: "Skip for Now"))
                let skip = try XCTUnwrap(visibleButton(String(localized: "Skip for Now"), in: page.view))
                XCTAssertTrue(skip.isEnabled)
                XCTAssertGreaterThanOrEqual(skip.bounds.height, 44)
                XCTAssertEqual(visibleButton(String(localized: "Try Again"), in: page.view) != nil, !outcome.succeeded)

                skip.sendActions(for: .touchUpInside)
                try await waitFor { presenter.presentedViewController == nil }
                XCTAssertEqual(monitor.outcome, outcome)
                XCTAssertEqual(monitor.changedTweaks, changedHere)
            }
        }
    }

    @MainActor
    func testFailedRunDisablesBothExitsWhileRetryIsBeingConfirmed() async throws {
        try await withResultSheet(monitor: monitor(), outcome: .failed("postrm failed"), changedTweaks: true) { presenter, page, _ in
            let retry = try XCTUnwrap(visibleButton(String(localized: "Try Again"), in: page.view))
            let skip = try XCTUnwrap(visibleButton(String(localized: "Skip for Now"), in: page.view))
            let reload = try XCTUnwrap(page.navigationItem.rightBarButtonItem)
            retry.sendActions(for: .touchUpInside)
            XCTAssertFalse(skip.isEnabled)
            XCTAssertFalse(reload.isEnabled)
            skip.sendActions(for: .touchUpInside)
            XCTAssertNotNil(presenter.presentedViewController)
            try await waitFor { skip.isEnabled && reload.isEnabled }
        }
    }

    @MainActor
    func testSkipIsAbsentForNormalCompletionAndAnAppUpdate() async throws {
        for updatesApp in [false, true] {
            let identity = updatesApp ? InstallerJob.selfIdentityPrefix + "test" : "test.old"
            try await withResultSheet(monitor: monitor(removing: identity), outcome: .succeeded, changedTweaks: updatesApp) { _, page, _ in
                XCTAssertEqual(page.navigationItem.rightBarButtonItem?.accessibilityLabel, String(localized: "Done"))
                XCTAssertNil(visibleButton(String(localized: "Skip for Now"), in: page.view))
            }
        }
    }

    @MainActor
    private func withResultSheet(
        monitor: OperationMonitor,
        outcome: OperationMonitor.Outcome,
        changedTweaks: Bool,
        followsTweakChange: Bool = false,
        pushed: Bool = false,
        verify: (UIViewController, OperationController, OperationMonitor) async throws -> Void
    ) async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
        let window = UIWindow(windowScene: scene)
        let presenter = UIViewController()
        window.rootViewController = presenter
        window.isHidden = false
        window.layoutIfNeeded()
        defer {
            presenter.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }

        var started = false
        var resprings = 0
        defer { XCTAssertEqual(resprings, 0) }
        let page = OperationController(
            operation: monitor.operation,
            followsTweakChange: followsTweakChange,
            services: .init(
                begin: { _ in
                    started = true
                    return monitor
                },
                confirmRetry: { false },
                respring: { resprings += 1 }
            )
        )
        let sheet = UINavigationController(rootViewController: pushed ? UIViewController() : page)
        sheet.modalPresentationStyle = .formSheet
        var presented = false
        presenter.present(sheet, animated: false) { presented = true }
        try await waitFor { presented }
        if pushed { sheet.pushViewController(page, animated: false) }
        try await waitFor { started }
        XCTAssertNil(visibleButton(String(localized: "Skip for Now"), in: page.view))
        monitor.finish(outcome, changedTweaks: changedTweaks)
        try await waitFor {
            guard let item = page.navigationItem.rightBarButtonItem else { return false }
            return item.customView == nil
        }
        page.view.layoutIfNeeded()
        try await verify(presenter, page, monitor)
    }

    @MainActor
    private func visibleButton(_ label: String, in view: UIView) -> UIButton? {
        guard !view.isHidden else { return nil }
        if let button = view as? UIButton, button.accessibilityLabel == label { return button }
        return view.subviews.lazy.compactMap { self.visibleButton(label, in: $0) }.first
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool, file: StaticString = #file, line: UInt = #line) async throws {
        for _ in 0 ..< 250 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        _ = try XCTUnwrap(condition() ? true : nil, "Timed out waiting for the operation sheet", file: file, line: line)
    }

    /// A file put in place, replaced under the same name or taken away is a
    /// change; reading again with nothing done is not, a directory reached
    /// through a link is read once, and roothide's hidden `.jbroot` link is
    /// no tweak.
    func testTweakInjectionSeesEveryChange() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TweakInjection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let tweaks = root.appendingPathComponent("usr/lib/TweakInject")
        try FileManager.default.createDirectory(at: tweaks, withIntermediateDirectories: true)
        let substrate = root.appendingPathComponent("Library/MobileSubstrate")
        try FileManager.default.createDirectory(at: substrate, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: substrate.appendingPathComponent("DynamicLibraries"),
            withDestinationURL: tweaks
        )
        let paths = TweakInjection.directories.map { root.path + $0 } + [root.path + "/missing"]

        let empty = TweakInjection.read(paths)
        XCTAssertEqual(TweakInjection.read(paths), empty)
        try FileManager.default.createSymbolicLink(
            at: tweaks.appendingPathComponent(".jbroot"),
            withDestinationURL: root
        )
        XCTAssertEqual(TweakInjection.read(paths), empty)

        let dylib = tweaks.appendingPathComponent("Example.dylib")
        try Data("one".utf8).write(to: dylib)
        let installed = TweakInjection.read(paths)
        XCTAssertNotEqual(installed, empty)
        XCTAssertEqual(TweakInjection.read(paths), installed)
        XCTAssertEqual(TweakInjection.read([tweaks.path]), installed)

        // a reinstall: the same name and size, a new file
        let staged = root.appendingPathComponent("Example.dylib")
        try Data("two".utf8).write(to: staged)
        XCTAssertEqual(rename(staged.path, dylib.path), 0)
        let reinstalled = TweakInjection.read(paths)
        XCTAssertNotEqual(reinstalled, installed)

        try FileManager.default.removeItem(at: dylib)
        XCTAssertEqual(TweakInjection.read(paths), empty)
    }
}

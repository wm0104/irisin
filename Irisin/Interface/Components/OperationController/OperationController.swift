import AptResolver
import Combine
import IrisinProtocol
import UIKit

/// The running operation, as the queue's own list: the same cards and rows
/// the user just reviewed, each row now filling with its package's progress
/// and counting it on a ring. The rows are the progress and the title says
/// how it ended; Try Again and Skip for Now are offered below the list,
/// and a line under the list fades in while the helper finishes
/// after the last row. A package that stopped the operation turns red and
/// opens the account of its failure; every row then says what is true of
/// its package, since the helper keeps what it finished. The helper's lines
/// are not on this page: a package's own are behind its row and the whole
/// log is in the menu at the leading edge. Everything on screen is a
/// binding to `OperationMonitor`; the controller decides nothing about the
/// operation.
final class OperationController: UIViewController, UITableViewDelegate {
    nonisolated enum Section: Hashable {
        case status
        case changes(QueueChange.Kind, dependencies: Bool)
        /// What the helper warned of that belongs to no package.
        case notices
    }

    nonisolated enum Row: Hashable {
        /// Recovery work that has stages but no package diff to draw.
        case maintenance
        case change(QueueChange)
        case notice(String)
    }

    /// The system effects behind the page: starting an operation, asking the
    /// owner to retry and reloading the home screen.
    @MainActor
    struct Services {
        var begin: @MainActor (Installer.OperationPayload) -> OperationMonitor = { Installer.shared.beginOperation(operation: $0) }
        var confirmRetry: @MainActor () async -> Bool = { await OperationConfirmation.confirm() }
        var respring: @MainActor () -> Void = {
            UIApplication.prepareForExitAndSuspend()
            Task { await PrivilegedBackend.run(.respring) }
        }
    }

    private let operation: Installer.OperationPayload
    private let quickOperation: QuickOperationIntent?
    let services: Services
    var isRecoveryMode: Bool {
        operation.plan.recoveryMode
    }

    private let changes: [String: QueueChange]
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private lazy var operationWarningBanner = OperationWarningBanner(
        title: operation.plan.recoveryMode ? "Recovery Mode" : "Ignoring Configuration Errors"
    )
    private lazy var icons = PackageIconCache { [weak self] in self?.reconfigure() }
    private(set) var monitor: OperationMonitor?
    let ignoresScriptFailures: Bool
    /// The run this one tried again changed the tweaks. This run reads the
    /// directories only after that, and would not see it on its own.
    private let followsTweakChange: Bool
    private var subscriptions = Set<AnyCancellable>()
    /// The row the list last scrolled to, so it follows a package once.
    private var followed: String?
    /// When the page appeared. A text button set in the bar while it still
    /// settles from Try Again's push came up white on white on iOS 26, so
    /// the closing button waits until the page has been up this long.
    private var appearedAt: Date?
    private static let barSettleInterval: TimeInterval = 1
    /// Under the list while every row is done and the helper still works:
    /// triggers, the home screen, the app reading the database back. Always
    /// in place so fading it moves nothing. The label fades, not the footer:
    /// a table's update animation sets its footer's alpha back to 1, and
    /// the failure row showed the line under a list that had stopped.
    private let finishingFooter = ListFootnoteView().then {
        $0.label.text = String(localized: "Finishing installation…")
        $0.label.alpha = 0
        $0.accessibilityElementsHidden = true
    }

    private let retrySpinner = UIActivityIndicatorView(style: .medium)
    private lazy var retryButton = resultButton(title: "Try Again") { [weak self] in self?.retry() }
    private lazy var skipButton = resultButton(title: "Skip for Now") { [weak self] in self?.skipHomeScreenReload() }

    private lazy var resultsFooter = UIView().then { footer in
        let stack = UIStackView(arrangedSubviews: [retryButton, retrySpinner, skipButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 4
        footer.insetsLayoutMarginsFromSafeArea = false
        footer.addSubview(stack)
        stack.snp.makeConstraints { x in
            x.edges.equalTo(footer.layoutMarginsGuide)
        }
        for button in [retryButton, skipButton] {
            button.snp.makeConstraints { x in
                // A hidden arranged subview has a required zero height.
                x.height.greaterThanOrEqualTo(44).priority(.high)
                x.width.equalToSuperview()
            }
        }
    }

    private func resultButton(title: String.LocalizationValue, action: @escaping @MainActor () -> Void) -> UIButton {
        let title = String(localized: title)
        return UIButton(type: .system).then { button in
            button.accessibilityLabel = title
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.textAlignment = .center
            button.titleLabel?.lineBreakMode = .byWordWrapping
            button.titleLabel?.font = .footnote
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            let titleColors: [(UIControl.State, UIColor)] = [(.normal, .buttonNormal), (.disabled, .textMuted)]
            for (state, color) in titleColors {
                button.setAttributedTitle(NSAttributedString(string: title, attributes: [
                    .foregroundColor: color,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ]), for: state)
            }
            button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        }
    }

    private var isFinishing = false
    /// Try Again was tapped and the queue is being staged. The button that
    /// closes the page waits with it, as Try Again does: the sheet closed
    /// while the run was staged threw the run away. It stays held once the
    /// run is pushed, which has no way back to this page.
    private(set) var retrying = false {
        didSet {
            retryButton.isEnabled = !retrying
            skipButton.isEnabled = !retrying
            navigationItem.rightBarButtonItems?.forEach { $0.isEnabled = !retrying }
            view.setNeedsLayout()
        }
    }

    private lazy var dataSource: EditableTableDiffableDataSource<Section, Row> = .init(
        tableView: tableView
    ) { [unowned self] (table: UITableView, indexPath: IndexPath, row: Row) -> UITableViewCell in
        switch row {
        case let .change(change):
            let cell = table.dequeueReusableCell(withIdentifier: "package", for: indexPath) as! OperationPackageCell
            cell.apply(change, icon: icons.icon(of: change.package), state: state(of: change), animated: false)
            return cell
        case .maintenance:
            let cell = table.dequeueReusableCell(withIdentifier: "maintenance", for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = monitor?.outcome == .succeeded
                ? String(localized: "Operation completed.")
                : String(localized: "Maintaining the system environment…")
            content.textProperties.font = .body
            if monitor?.outcome == .succeeded {
                content.image = UIImage(systemName: "checkmark.circle.fill")
                content.imageProperties.tintColor = .operationSucceeded
                cell.accessoryView = nil
            } else {
                cell.accessoryView = UIActivityIndicatorView(style: .medium).then { $0.startAnimating() }
            }
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            cell.accessibilityTraits = .staticText
            return cell
        case let .notice(text):
            let cell = table.dequeueReusableCell(withIdentifier: "plain", for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = text
            content.textProperties.font = .footnote
            content.image = UIImage(systemName: "exclamationmark.triangle")
            content.imageProperties.tintColor = .operationWarning
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        }
    }

    init(
        operation: Installer.OperationPayload,
        followsTweakChange: Bool = false,
        quickOperation: QuickOperationIntent? = nil,
        services: Services = .init()
    ) {
        self.operation = operation
        self.followsTweakChange = followsTweakChange
        self.quickOperation = quickOperation
        self.services = services
        // read now: a finished operation empties the queue
        changes = QueueChange.changes(
            of: operation.plan,
            requested: operation.plan.recoveryMode
                ? Set((operation.plan.install + operation.plan.remove).map(\.identity))
                : Set(PackageQueue.shared.actions.map(\.identity))
        )
        ignoresScriptFailures = operation.transaction.ignoreScriptFailures
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(operation:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let removesOnly = !operation.plan.remove.isEmpty && operation.plan.stages.allSatisfy {
            if case .remove = $0 { return true }
            return false
        }
        title = removesOnly ? String(localized: "Removing…") : String(localized: "Installing")
        isModalInPresentation = true
        navigationController?.isModalInPresentation = true
        navigationItem.largeTitleDisplayMode = .always
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.leftBarButtonItems = [menuItem()]
        let activity = UIActivityIndicatorView(style: .medium)
        activity.color = .buttonNormal
        activity.isAccessibilityElement = true
        activity.accessibilityLabel = String(localized: "Operation in Progress")
        activity.startAnimating()
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: activity)

        tableView.backgroundColor = .groupedBackground
        tableView.register(OperationPackageCell.self, forCellReuseIdentifier: "package")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "plain")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "maintenance")
        tableView.delegate = self
        tableView.dataSource = dataSource
        dataSource.defaultRowAnimation = .fade
        dataSource.headerTitle = { section in
            switch section {
            case let .changes(kind, dependencies): kind.title(dependencies: dependencies)
            case .notices: String(localized: "Warnings")
            case .status: nil
            }
        }
        view.addSubview(tableView)
        tableView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }
        updateOperationWarningBanner()
        applySnapshot()
    }

    /// The footer's height is its text's at this width and text size.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = tableView.bounds.width
        guard width > 0 else { return }
        updateOperationWarningBanner()
        let footer: UIView
        let height: CGFloat
        let showsRetry = monitor?.outcome?.succeeded == false
        let showsSkip = monitor.map { $0.outcome != nil && ending(of: $0) == .reloadHomeScreen } ?? false
        if showsRetry || showsSkip {
            footer = resultsFooter
            retryButton.isHidden = !showsRetry
            skipButton.isHidden = !showsSkip
            if showsRetry && retrying {
                retrySpinner.startAnimating()
            } else {
                retrySpinner.stopAnimating()
            }
            retrySpinner.isHidden = !showsRetry || !retrying
            resultsFooter.layoutMargins = UIEdgeInsets(
                top: 8,
                left: 20 + view.safeAreaInsets.left,
                bottom: 8,
                right: 20 + view.safeAreaInsets.right
            )
            height = resultsFooter.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
        } else {
            footer = finishingFooter
            height = finishingFooter.label
                .sizeThatFits(CGSize(width: width - 40, height: .greatestFiniteMagnitude))
                .height + 32
        }
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        guard tableView.tableFooterView !== footer || footer.frame != frame else { return }
        footer.frame = frame
        tableView.tableFooterView = footer
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard monitor == nil else { return }
        if let quickOperation {
            let queue = PackageQueue.shared
            // The queue can move while this sheet is still animating in.
            guard quickOperation.canStart(plan: queue.plan?.id, blocked: queue.blocked != nil) else {
                dismiss(animated: true)
                return
            }
        }
        appearedAt = Date()
        let monitor = services.begin(operation)
        self.monitor = monitor
        bind(monitor)
    }

    // MARK: - Content

    private func state(of change: QueueChange) -> OperationPackages.State {
        monitor?.packages.states[change.package.identity] ?? .init()
    }

    /// The packages alone while the operation runs: the rows are the
    /// progress. Warnings close the list; result actions go below it.
    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        if Self.showsMaintenanceRow(changeCount: changes.count, outcome: monitor?.outcome) {
            snapshot.appendSections([.status])
            snapshot.appendItems([.maintenance], toSection: .status)
        }
        for group in QueueChange.sections(of: changes.values) {
            let section = Section.changes(group.kind, dependencies: group.dependencies)
            snapshot.appendSections([section])
            snapshot.appendItems(group.changes.map(Row.change), toSection: section)
        }
        var notices = monitor?.outcome == nil ? [] : notices()
        if let monitor, case let .failed(reason) = monitor.outcome,
           !monitor.packages.states.contains(where: { changes[$0.key] != nil && $0.value.hasProblem })
        {
            notices.insert(reason, at: 0)
        }
        notices = notices.uniqued()
        if !notices.isEmpty {
            snapshot.appendSections([.notices])
            snapshot.appendItems(notices.map(Row.notice), toSection: .notices)
        }
        snapshot.reconfigureItems(survivingFrom: dataSource.snapshot())
        dataSource.apply(snapshot, animatingDifferences: view.shouldAnimateDiff)
    }

    /// A recovery plan may only finish maintainer scripts or triggers. It has
    /// real stages but no install/remove diff, so give the running page one
    /// stable row instead of presenting an empty list.
    static func showsMaintenanceRow(changeCount: Int, outcome: OperationMonitor.Outcome?) -> Bool {
        changeCount == 0 && outcome?.succeeded != false
    }

    /// An icon arrived.
    private func reconfigure() {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// The warnings that are no package's own: a package that needs repair
    /// says so on its row.
    private func notices() -> [String] {
        (monitor?.transcript ?? []).compactMap { event -> String? in
            guard case let .warning(problem) = event else { return nil }
            switch problem {
            case let .packageNeedsRepair(identity) where changes[identity] != nil:
                return nil
            case let .scriptFailureIgnored(identity, _, _) where changes[identity] != nil:
                return nil
            default:
                break
            }
            return problem.localizedDescription
        }.uniqued()
    }

    /// How a failed operation went: the rows counted when it stopped at a
    /// package, the reason itself when it stopped anywhere else.
    private func statusContent() -> UIListContentConfiguration {
        var content = UIListContentConfiguration.subtitleCell()
        content.textProperties.font = .subheadlineEmphasized
        content.textProperties.color = .textTitle
        content.secondaryTextProperties.font = .footnote
        content.secondaryTextProperties.color = .textSubtitle
        content.image = UIImage(systemName: "exclamationmark.triangle.fill")
        content.imageProperties.tintColor = .operationFailed
        guard let monitor, case let .failed(reason) = monitor.outcome else { return content }
        // the packages with a row: one only set up again has none to point at
        let states = monitor.packages.states.filter { changes[$0.key] != nil }.values
        let failed = states.filter {
            if case .failed = $0.status {
                true
            } else {
                false
            }
        }.count
        if failed > 0 {
            // the rows carry the reasons; this counts them
            let done = states.filter { $0.status == .done }.count
            let incomplete = states.filter { $0.status == .incomplete }.count
            let notStarted = states.filter { $0.status == .notStarted }.count
            content.text = ListFormatter.localizedString(byJoining: [
                done > 0 ? String(localized: "\(done) completed") : nil,
                String(localized: "\(failed) failed"),
                incomplete > 0 ? String(localized: "\(incomplete) not set up") : nil,
                notStarted > 0 ? String(localized: "\(notStarted) not started") : nil,
            ].compactMap(\.self))
            content.secondaryText = String(localized: "Select a marked package to see what went wrong.")
        } else {
            content.text = reason
            if states.contains(where: { $0.status == .done }) {
                content.secondaryText = String(localized: "The packages marked as completed were changed before it stopped.")
            }
        }
        return content
    }

    // MARK: - Binding

    /// Events arrive in bursts while files land; the rows are refreshed at
    /// most ten times a second and always end on the latest state.
    private func bind(_ monitor: OperationMonitor) {
        monitor.$packages
            .removeDuplicates()
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] packages in
                guard let self else { return }
                refreshVisibleRows()
                follow(packages.current)
                updateFinishingFooter()
            }
            .store(in: &subscriptions)
        monitor.$outcome
            .compactMap(\.self)
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] outcome in
                guard let self else { return }
                title = outcome.succeeded ? String(localized: "Completed") : String(localized: "Failed")
                refreshVisibleRows()
                applySnapshot()
                updateFinishingFooter()
                view.setNeedsLayout()
                let settled = Self.barSettleInterval - Date().timeIntervalSince(appearedAt ?? .distantPast)
                Task { [weak self] in
                    if settled > 0 {
                        try? await Task.sleep(seconds: settled)
                    }
                    guard let self else { return }
                    finishOperation(succeeded: outcome.succeeded, ending: ending(of: monitor))
                }
                UIAccessibility.post(
                    notification: .announcement,
                    argument: outcome.succeeded ? String(localized: "Operation completed.") : statusContent().text
                )
            }
            .store(in: &subscriptions)
    }

    /// The monitor's, but a sheet whose earlier run changed the tweaks
    /// still has them to load when this one changed none.
    private func ending(of monitor: OperationMonitor) -> OperationMonitor.Ending {
        monitor.ending == .close && followsTweakChange ? .reloadHomeScreen : monitor.ending
    }

    private func refreshVisibleRows() {
        for case let cell as OperationPackageCell in tableView.visibleCells {
            guard let change = cell.change else { continue }
            cell.apply(change, icon: icons.icon(of: change.package), state: state(of: change), animated: true)
        }
    }

    /// Reads the outcome itself, not the published one: a throttled package
    /// update can land after the operation ended. Only the packages with a
    /// row count: one the helper found already configured says nothing and
    /// stays waiting.
    private func updateFinishingFooter() {
        guard let monitor else { return }
        let states = monitor.packages.states.filter { changes[$0.key] != nil }.values
        let finishing = monitor.outcome == nil && !states.isEmpty && states.allSatisfy { $0.status == .done }
        guard finishing != isFinishing else { return }
        isFinishing = finishing
        finishingFooter.accessibilityElementsHidden = !finishing
        UIView.animate(withDuration: 0.3) { self.finishingFooter.label.alpha = finishing ? 1 : 0 }
        if finishing, !tableView.isTracking, !tableView.isDecelerating {
            tableView.scrollRectToVisible(finishingFooter.frame, animated: true)
        }
    }

    /// Keeps the package the helper works on in sight, unless the user is
    /// looking around.
    private func follow(_ identity: String?) {
        guard let identity, identity != followed, let change = changes[identity],
              let indexPath = dataSource.indexPath(for: .change(change)),
              !tableView.isTracking, !tableView.isDecelerating
        else { return }
        followed = identity
        tableView.scrollToRow(at: indexPath, at: .none, animated: true)
    }

    /// Try Again: the queue, solved again against what the failed run left,
    /// is staged and run in this sheet, as Execute would run it. A Bootstrap
    /// Install is tried again as one, configuring what it left unpacked.
    private func retry(ignoreScriptFailures: Bool? = nil) {
        guard !retrying else { return }
        retrying = true
        let confirmRetry = services.confirmRetry
        Task { [weak self] in
            guard await confirmRetry() else {
                self?.retrying = false
                return
            }
            let manager = PackageQueue.shared
            await manager.settled()
            guard let self, view.window != nil else { return }
            let payload: Installer.OperationPayload? = if operation.plan.recoveryMode,
                                                          operation.plan.install.count == 1,
                                                          let package = operation.plan.install.first
            {
                await Installer.shared.createRecoveryOperationPayload(package: package)
            } else if operation.plan.recoveryMode,
                      operation.plan.remove.count == 1,
                      let package = operation.plan.remove.first
            {
                await Installer.shared.createRecoveryRemovalPayload(identity: package.identity)
            } else if manager.blocked == nil, let plan = manager.plan {
                await Installer.shared.createOperationPayload(
                    plan: plan,
                    ignoreScriptFailures: ignoreScriptFailures ?? ignoresScriptFailures,
                    bootstrapInstall: operation.transaction.bootstrapInstall && plan.allowsBootstrapInstall
                )
            } else {
                nil
            }
            // Staging took time; a sheet closed meanwhile has nothing to run.
            guard view.window != nil else { return }
            guard let payload, !payload.transaction.stages.isEmpty else {
                retrying = false
                reconfigure()
                // staging said why in the report when it could
                let report = PackageActionReport.shared.allAvailable()
                let fallback = String(localized: "Unable to prepare this operation. Try again.")
                return presentNotice(
                    title: "Unable to Try Again",
                    message: manager.blocked ?? (report.isEmpty ? fallback : report)
                )
            }
            let next = OperationController(
                operation: payload,
                followsTweakChange: followsTweakChange || monitor?.changedTweaks == true
            )
            navigationController?.pushViewController(next, animated: true)
        }
    }

    /// Confirm once, then stage a new transaction with script failures tolerated.
    func retryIgnoringScriptFailures() {
        guard !retrying else { return }
        presentConfirmation(
            title: "Ignore Script Errors and Retry?",
            message: "Irisin will retry the operation and continue if a package script fails. This can damage installed packages or the system.",
            confirmTitle: "Retry",
            destructive: true
        ) { [weak self] in
            guard let self else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            retry(ignoreScriptFailures: true)
        }
    }

    private func updateOperationWarningBanner() {
        guard ignoresScriptFailures || operation.plan.recoveryMode else {
            tableView.tableHeaderView = nil
            return
        }
        let width = tableView.bounds.width
        guard width > 0 else { return }
        let size = operationWarningBanner.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        guard tableView.tableHeaderView !== operationWarningBanner
            || operationWarningBanner.frame.size != CGSize(width: width, height: size.height)
        else { return }
        operationWarningBanner.frame = CGRect(x: 0, y: 0, width: width, height: size.height)
        tableView.tableHeaderView = operationWarningBanner
    }

    // MARK: - Problems

    /// A package row opens only once it has a problem to show.
    func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case let .change(change): state(of: change).hasProblem
        default: false
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let monitor, case let .change(change) = dataSource.itemIdentifier(for: indexPath) else { return }
        let problem = OperationProblemController(
            change: change,
            icon: icons.icon(of: change.package),
            state: state(of: change),
            output: monitor.packageOutput[change.package.identity] ?? []
        )
        navigationController?.pushViewController(problem, animated: true)
    }
}

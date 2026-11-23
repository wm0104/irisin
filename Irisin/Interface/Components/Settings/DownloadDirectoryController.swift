import UIKit
import UniformTypeIdentifiers

/// A native folder picker, with the app's normal page and notice transitions.
final class DownloadDirectoryController: UITableViewController, UIDocumentPickerDelegate {
    nonisolated enum Action: Hashable, Sendable { case open, choose, reset }
    nonisolated enum Section: Hashable { case current, actions }
    nonisolated enum Row: Hashable { case current, action(Action) }

    private let listUpdates = WindowedListUpdates()
    private lazy var dataSource = EditableTableDiffableDataSource<Section, Row>(tableView: tableView) { [unowned self] table, index, row in
        let cell = table.dequeueReusableCell(withIdentifier: "folder", for: index)
        configure(cell, for: row)
        return cell
    }

    private var initialAction: Action?
    private let changed: () -> Void
    private var access: DownloadDirectory.Lease?
    private var busy = false
    private var failure: String?
    private let ring = ProgressRing()

    init(action: Action? = nil, changed: @escaping () -> Void = {}) {
        initialAction = action
        self.changed = changed
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Downloads Folder")
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .groupedBackground
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "folder")
        ring.frame.size = CGSize(width: ProgressRing.diameter, height: ProgressRing.diameter)
        tableView.dataSource = dataSource
        dataSource.footerTitle = { [weak self] section in
            section == .current ? self?.failure : String(localized: "Only future completed downloads use this folder. Existing files stay where they are. Partial downloads and installation staging are unchanged.")
        }
        updateRows()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        listUpdates.applyPending()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let action = initialAction {
            initialAction = nil
            perform(action)
        } else if access == nil, !busy {
            check()
        }
    }

    /// An explicit choice has a bookmark even when its URL is the default.
    /// A configuration that fails to decode can still be replaced by a reset.
    private static var offersResetForConfiguration: Bool {
        guard let configuration = try? DownloadDirectory.configuration() else { return true }
        return configuration.url != DownloadDirectory.defaultURL || configuration.bookmark != nil
    }

    private var canRestoreDefault: Bool { failure != nil || Self.offersResetForConfiguration }

    static func menu(from host: UIViewController, changed: @escaping () -> Void) -> [UIMenuElement] {
        var actions: [UIMenuElement] = [
            UIAction(title: String(localized: "Open Current Folder"), image: UIImage(systemName: "folder")) { [weak host] _ in
                host?.present(next: DownloadDirectoryController(action: .open, changed: changed))
            },
            UIAction(title: String(localized: "Choose Folder…"), image: UIImage(systemName: "folder.badge.plus")) { [weak host] _ in
                host?.present(next: DownloadDirectoryController(action: .choose, changed: changed))
            },
        ]
        if offersResetForConfiguration {
            actions.append(UIAction(title: String(localized: "Restore Default Folder"), image: UIImage(systemName: "arrow.counterclockwise")) { [weak host] _ in
                host?.present(next: DownloadDirectoryController(action: .reset, changed: changed))
            })
        }
        return actions
    }

    private func updateRows() {
        listUpdates.apply("folders", to: tableView, animated: false) { [weak self] _ in
            guard let self else { return }
            var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
            snapshot.appendSections([.current, .actions])
            snapshot.appendItems([.current], toSection: .current)
            snapshot.appendItems([.action(.open), .action(.choose)], toSection: .actions)
            if canRestoreDefault {
                snapshot.appendItems([.action(.reset)], toSection: .actions)
            }
            snapshot.reconfigureItems(survivingFrom: dataSource.snapshot())
            dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    private func configure(_ cell: UITableViewCell, for row: Row) {
        var content = cell.defaultContentConfiguration()
        switch row {
        case .current:
            content.text = DownloadDirectory.currentURL?.path ?? String(localized: "Folder Unavailable")
            content.secondaryText = busy ? String(localized: "Checking Folder…") : failure == nil ? String(localized: "Downloads Folder") : String(localized: "Folder Unavailable")
            content.textProperties.numberOfLines = 0
            content.secondaryTextProperties.numberOfLines = 0
            cell.accessoryView = busy ? ring : nil
            cell.selectionStyle = .none
        case let .action(action):
            content.text = switch action {
            case .open: String(localized: "Open Current Folder")
            case .choose: String(localized: "Choose Folder…")
            case .reset: String(localized: "Restore Default Folder")
            }
            content.textProperties.color = busy ? .secondaryLabel : .tintColor
            cell.accessoryView = nil
            cell.selectionStyle = busy ? .none : .default
        }
        cell.contentConfiguration = content
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !busy, case let .action(action) = dataSource.itemIdentifier(for: indexPath) else { return }
        perform(action)
    }

    private func perform(_ action: Action) {
        guard !busy else { return }
        switch action {
        case .open: check(open: true)
        case .choose:
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            picker.allowsMultipleSelection = false
            picker.delegate = self
            present(picker, animated: true)
        case .reset:
            guard canRestoreDefault else { return updateRows() }
            presentConfirmation(
                title: "Restore Default Folder?",
                message: "Only future completed downloads use the default folder. Existing files will not be moved or deleted."
            ) { [weak self] in self?.change(to: nil) }
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        // Keep the picked grant alive while dismissal and off-main validation run.
        do {
            let picked = try DownloadDirectory.Lease(url: url, configuration: .init(url: url, bookmark: nil))
            Task { [weak self] in
                await controller.dismissFinishing(animated: true)
                self?.change(to: url, picked: picked)
            }
        } catch {
            Task { [weak self] in
                await controller.dismissFinishing(animated: true)
                self?.show(error)
            }
        }
    }

    func documentPickerWasCancelled(_: UIDocumentPickerViewController) { check() }

    private func change(to url: URL?, picked: DownloadDirectory.Lease? = nil) {
        guard !busy else { return }
        setBusy(true)
        Task { [weak self] in
            do {
                let lease = try await Self.update(url, picked: picked)
                guard let self else { return }
                access = lease
                failure = nil
                setBusy(false)
                changed()
            } catch {
                guard let self else { return }
                setBusy(false)
                show(error)
            }
        }
    }

    private func check(open: Bool = false) {
        guard !busy else { return }
        setBusy(true)
        Task { [weak self] in
            do {
                let lease = try await Self.checked()
                guard let self else { return }
                access = lease
                failure = nil
                setBusy(false)
                if open { openInFila(path: lease.url.path) }
            } catch {
                guard let self else { return }
                setBusy(false)
                show(error)
            }
        }
    }

    private func setBusy(_ value: Bool) {
        busy = value
        ring.set(value ? .working(0) : .waiting, animated: true)
        updateRows()
    }

    private func show(_ error: Error) {
        failure = error.localizedDescription
        updateRows()
        presentNotice(title: "Downloads Folder", message: error.localizedDescription)
    }

    @concurrent
    private nonisolated static func checked() async throws -> DownloadDirectory.Lease {
        let lease = try DownloadDirectory.acquire()
        try DownloadDirectory.validate(lease)
        return lease
    }

    @concurrent
    private nonisolated static func update(_ url: URL?, picked: DownloadDirectory.Lease?) async throws -> DownloadDirectory.Lease {
        defer { withExtendedLifetime(picked) {} }
        if let url { try DownloadDirectory.select(url) }
        else { try DownloadDirectory.reset() }
        return try DownloadDirectory.acquire()
    }
}

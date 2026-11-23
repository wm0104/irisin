import IrisinProtocol
import UIKit
import UniformTypeIdentifiers

final class ConfigurationBackupController: UITableViewController, UIDocumentPickerDelegate {
    nonisolated enum Section: Hashable { case actions, history }
    nonisolated enum Row: Hashable { case choose, open, create, record(URL), empty }

    private let model: ConfigurationBackupModel
    private let backendAvailable: () -> Bool
    private let confirmOwner: @MainActor () async -> Bool
    private let listUpdates = WindowedListUpdates()
    private var running = false
    private var leaving = false
    private var loadedHistory = false
    private var previousPopEnabled: Bool?
    private var previousModalLock = false

    private lazy var dataSource = EditableTableDiffableDataSource<Section, Row>(tableView: tableView) { [unowned self] table, index, row in
        let identifier = row == .empty ? "empty" : "backup"
        let cell = table.dequeueReusableCell(withIdentifier: identifier, for: index) as! SettingsCell
        cell.configure(with: item(for: row))
        return cell
    }

    init(
        model: ConfigurationBackupModel = ConfigurationBackupModel(),
        backendAvailable: @escaping () -> Bool = { if case .daemon = PrivilegedBackend.backend { true } else { false } },
        confirmOwner: @escaping @MainActor () async -> Bool = { await OperationConfirmation.confirm() }
    ) {
        self.model = model
        self.backendAvailable = backendAvailable
        self.confirmOwner = confirmOwner
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Configuration Backup and Restore")
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .groupedBackground
        tableView.separatorStyle = .none
        tableView.register(SettingsDisclosureCell.self, forCellReuseIdentifier: "backup")
        tableView.register(SettingsValueCell.self, forCellReuseIdentifier: "empty")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "arrow.clockwise"),
            primaryAction: UIAction { [weak self] _ in self?.reload() }
        )
        navigationItem.rightBarButtonItem?.accessibilityLabel = String(localized: "Refresh")
        tableView.dataSource = dataSource
        dataSource.headerTitle = { section in
            section == .history ? String(localized: "Recent Backups") : nil
        }
        dataSource.footerTitle = { section in
            section == .actions
                ? String(localized: "Backups contain six configuration folders and repository sources, not installed packages or DEB files. Files are stored in plain text; choose a private local folder.")
                : String(localized: "Only the two newest Irisin backups are kept after a successful backup. Other files are left alone.")
        }
        updateRows()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        leaving = false
        listUpdates.applyPending()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !loadedHistory, !running, presentedViewController == nil else { return }
        loadedHistory = true
        if model.directory.hasSelection { reload() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            leaving = true
        }
    }

    private var canPresent: Bool {
        !leaving && viewIfLoaded?.window != nil && presentedViewController == nil
            && (navigationController == nil || navigationController?.topViewController === self)
    }

    private func item(for row: Row) -> SettingsItem {
        switch row {
        case .choose:
            SettingsItem(id: "choose", icon: "folder.badge.plus", title: String(localized: "Choose Backup Folder"), kind: .disclosure, action: { [weak self] in self?.chooseFolder() })
        case .open:
            SettingsItem(id: "open", icon: "folder", title: String(localized: "Open Backup Folder"), kind: .disclosure, action: { [weak self] in self?.openFolder() })
        case .create:
            SettingsItem(id: "create", icon: "plus.circle", title: String(localized: "Create Backup"), kind: .disclosure, action: { [weak self] in self?.requestCreate() })
        case let .record(url):
            SettingsItem(id: url.absoluteString, icon: "archivebox", title: recordTitle(url), kind: .disclosure, menu: { [weak self] in self?.restoreMenu(for: url) ?? [] })
        case .empty:
            SettingsItem(id: "empty", icon: "archivebox", title: String(localized: "No Backups"), kind: .value)
        }
    }

    private func recordTitle(_ url: URL) -> String {
        guard let record = model.records.first(where: { $0.url == url }) else { return url.lastPathComponent }
        return record.displayName
    }

    private func updateRows() {
        listUpdates.apply("backups", to: tableView, animated: false) { [weak self] _ in
            guard let self else { return }
            var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
            snapshot.appendSections([.actions, .history])
            snapshot.appendItems([.choose, .open, .create], toSection: .actions)
            snapshot.appendItems(model.records.isEmpty ? [.empty] : model.records.map { .record($0.url) }, toSection: .history)
            snapshot.reconfigureItems(survivingFrom: dataSource.snapshot())
            dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !running, let row = dataSource.itemIdentifier(for: indexPath) else { return }
        item(for: row).action?()
    }

    func restoreMenu(for url: URL) -> [UIMenuElement] {
        [
            UIAction(title: String(localized: "Restore Configuration")) { [weak self] _ in
                self?.requestRestore(url, preferences: true, sources: false)
            },
            UIAction(title: String(localized: "Restore Sources")) { [weak self] _ in
                self?.requestRestore(url, preferences: false, sources: true)
            },
            UIAction(title: String(localized: "Restore All")) { [weak self] _ in
                self?.requestRestore(url, preferences: true, sources: true)
            },
        ]
    }

    private func requireBackend() -> Bool {
        guard backendAvailable() else {
            presentNotice(title: "Browsing Only", message: "Install the Irisin package to use this action.")
            return false
        }
        return true
    }

    private func requestCreate() {
        guard !running, canPresent, requireBackend() else { return }
        guard let id = model.directory.selectionID else {
            showError(model.directory.hasSelection ? ConfigurationBackupDirectory.Failure.unavailable : .selectFolder)
            return
        }
        if model.directory.retentionAccepted { create(); return }
        // No pending state before a cancellable confirmation: Cancel leaves the page usable.
        presentConfirmation(
            title: "Keep Only Two Backups?",
            message: "After a successful backup, older Irisin backups in this folder will be permanently deleted, keeping only the newest two. Other files are not deleted.",
            confirmTitle: "Agree and Create Backup",
            destructive: true
        ) { [weak self] in
            guard let self, canPresent else { return }
            do {
                try model.directory.acceptRetention(for: id)
                create()
            } catch { showError(error) }
        }
    }

    private func create() {
        perform(title: "Creating Backup…", refreshHistory: true) { [self] in
            let record = try await model.create()
            return record.cleanupWarning
        }
    }

    private func requestRestore(_ url: URL, preferences: Bool, sources: Bool) {
        guard !running, canPresent, requireBackend(), let record = model.records.first(where: { $0.url == url }) else { return }
        presentConfirmation(
            title: "Restore Backup?",
            message: "The selected configuration folders and/or repository sources will be replaced in full. Current files not in the backup will be deleted. No pre-restore backup is created. The home screen will not reload automatically.",
            confirmTitle: "Restore",
            destructive: true
        ) { [weak self] in
            guard let self, canPresent else { return }
            perform(title: "Restoring Backup…") { [self] in
                try await model.restore(record, preferences: preferences, sources: sources)
                return nil
            }
        }
    }

    private func setRunning(_ value: Bool) {
        running = value
        tableView.isUserInteractionEnabled = !value
        navigationItem.rightBarButtonItem?.isEnabled = !value
        navigationItem.setHidesBackButton(value, animated: false)
        isModalInPresentation = value
        if value {
            previousPopEnabled = navigationController?.interactivePopGestureRecognizer?.isEnabled
            previousModalLock = navigationController?.isModalInPresentation ?? false
            navigationController?.interactivePopGestureRecognizer?.isEnabled = false
            navigationController?.isModalInPresentation = true
        } else {
            if let previousPopEnabled { navigationController?.interactivePopGestureRecognizer?.isEnabled = previousPopEnabled }
            navigationController?.isModalInPresentation = previousModalLock
            previousPopEnabled = nil
        }
    }

    private func perform(title: String.LocalizationValue, refreshHistory: Bool = false, work: @escaping @MainActor () async throws -> String?) {
        guard !running, canPresent else { return }
        setRunning(true)
        Task { [self] in
            defer { setRunning(false) }
            guard await confirmOwner(), canPresent else { return }
            let alert = progressAlert(title: title, message: "Keep Irisin open until this operation finishes.")
            alert.isModalInPresentation = true
            await withCheckedContinuation { shown in
                present(alert, animated: true) { shown.resume() }
            }
            var warning: String?
            var failure: (any Error)?
            do { warning = try await work() }
            catch { failure = error }
            // The progress container must be entirely gone before any following notice.
            await alert.dismissFinishing(animated: true)
            if refreshHistory, failure == nil {
                do { try await model.reload() }
                catch { failure = error }
            }
            updateRows()
            guard canPresent else { return }
            if let failure { showError(failure) }
            else if let warning { presentNotice(title: "Backup Cleanup Warning", message: warning) }
            else { presentNotice(title: "Operation Completed") }
        }
    }

    private func reload() {
        guard !running else { return }
        setRunning(true)
        Task { [self] in
            defer { setRunning(false) }
            do { try await model.reload() }
            catch { if canPresent { showError(error) } }
            updateRows()
        }
    }

    private func showError(_ error: any Error) {
        guard canPresent else { return }
        presentNotice(title: "Unable to Complete Backup Operation", message: error.localizedDescription)
    }

    private func chooseFolder() {
        guard !running, canPresent else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        Task { [weak self] in
            await controller.dismissFinishing(animated: true)
            guard let self, canPresent, !running, let url = urls.first else { return }
            do {
                try model.directory.select(url)
                reload()
            } catch { showError(error) }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // Selection and consent are unchanged, and there is no pending operation to release.
        controller.dismiss(animated: true)
    }

    private func openFolder() {
        guard !running, canPresent else { return }
        setRunning(true)
        Task { [self] in
            defer { setRunning(false) }
            do {
                try await model.directory.withAccess { url in
                    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    components?.scheme = "shareddocuments"
                    guard let destination = components?.url else { throw ConfigurationBackupDirectory.Failure.unavailable }
                    let opened = await withCheckedContinuation { finished in
                        UIApplication.shared.open(destination, options: [:]) { finished.resume(returning: $0) }
                    }
                    guard opened else { throw ConfigurationBackupDirectory.Failure.unavailable }
                }
            } catch { if canPresent { showError(error) } }
        }
    }
}

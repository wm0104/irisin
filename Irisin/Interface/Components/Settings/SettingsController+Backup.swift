import UIKit

extension SettingsController {
    func backupItems() -> [SettingsItem] {
        [
            SettingsItem(
                id: "configuration.backups",
                icon: "externaldrive.badge.timemachine",
                title: String(localized: "Configuration Backup and Restore"),
                kind: .disclosure,
                action: { [weak self] in
                    self?.present(next: ConfigurationBackupController())
                }
            ),
        ]
    }
}

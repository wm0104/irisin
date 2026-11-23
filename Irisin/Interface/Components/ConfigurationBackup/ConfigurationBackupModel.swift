// Configuration backup behavior adapted from Dopamine2-roothide d047e3a.
// https://github.com/wm0104/Dopamine2-roothide
// MIT License
//
// Copyright (c) 2023-2024 Lars Fröder (opa334)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Foundation
import IrisinClient
import IrisinProtocol

/// The UI's service seam. Fixtures replace I/O, never the backup algorithm.
@MainActor
final class ConfigurationBackupModel {
    struct Operations {
        var records: @MainActor (URL) async throws -> [ConfigurationBackupRecord]
        var create: @MainActor (URL, Bool) async throws -> ConfigurationBackupRecord
        var restore: @MainActor (URL, Bool, Bool) async throws -> Void

        static func live() -> Operations {
            let link = PrivilegedBackend.link
            return Operations(
                records: { url in
                    try await Task.detached(priority: .userInitiated) {
                        try ConfigurationBackupStorage.records(in: url)
                    }.value
                },
                create: { url, pruning in
                    try await Task.detached(priority: .userInitiated) {
                        try await ConfigurationBackupService(link: link).create(in: url, allowPruning: pruning)
                    }.value
                },
                restore: { url, preferences, sources in
                    try await Task.detached(priority: .userInitiated) {
                        try await ConfigurationBackupService(link: link).restore(from: url, preferences: preferences, sources: sources)
                    }.value
                }
            )
        }
    }

    nonisolated enum Failure: LocalizedError {
        case busy, retentionRequired, missingRecord

        var errorDescription: String? {
            switch self {
            case .busy: String(localized: "A backup operation is already running.")
            case .retentionRequired: String(localized: "Confirm the two-backup retention rule before creating a backup.")
            case .missingRecord: String(localized: "This backup is no longer in the selected folder. Refresh the list and try again.")
            }
        }
    }

    let directory: ConfigurationBackupDirectory
    private let operations: Operations
    private(set) var isBusy = false
    private(set) var records: [ConfigurationBackupRecord] = []

    init(directory: ConfigurationBackupDirectory = ConfigurationBackupDirectory(), operations: Operations = .live()) {
        self.directory = directory
        self.operations = operations
    }

    func reload() async throws {
        guard !isBusy else { throw Failure.busy }
        isBusy = true
        defer { isBusy = false }
        // An inaccessible folder must not leave actionable records from an old grant.
        records = []
        records = try await directory.withAccess { url in
            try await operations.records(url).sorted { $0.created > $1.created }
        }
    }

    func create() async throws -> ConfigurationBackupRecord {
        guard !isBusy else { throw Failure.busy }
        guard directory.retentionAccepted else { throw Failure.retentionRequired }
        isBusy = true
        defer { isBusy = false }
        return try await directory.withAccess { url in
            try await operations.create(url, true)
        }
    }

    func restore(_ record: ConfigurationBackupRecord, preferences: Bool, sources: Bool) async throws {
        guard !isBusy else { throw Failure.busy }
        isBusy = true
        defer { isBusy = false }
        try await directory.withAccess { url in
            guard (preferences || sources),
                  record.url.deletingLastPathComponent().standardizedFileURL == url.standardizedFileURL,
                  records.contains(where: { $0.url == record.url })
            else { throw Failure.missingRecord }
            try await operations.restore(record.url, preferences, sources)
        }
    }
}

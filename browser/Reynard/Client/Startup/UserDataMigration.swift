//
//  UserDataMigration.swift
//  Reynard
//
//  Created by Minh Ton on 17/5/26.
//

import Foundation

final class UserDataMigration {
    static let shared = UserDataMigration()

    private struct LegacyDirectoryMigrationJournal: Codable {
        static let currentVersion = 1

        enum Phase: String, Codable {
            case prepared
            case committed
        }

        let version: Int
        let destinationExisted: Bool
        let phase: Phase
    }

    private enum LegacyDirectoryMigrationError: Error {
        case unsupportedJournalVersion
        case missingDestination
    }
    
    private let fileManager: FileManager
    private let documentsDirectoryURL: URL
    private let applicationSupportDirectoryURL: URL
    
    private var documentsAppDataDirectoryURL: URL {
        documentsDirectoryURL.appendingPathComponent("AppData", isDirectory: true)
    }
    
    private var documentsDDIDirectoryURL: URL {
        documentsDirectoryURL.appendingPathComponent("DDI", isDirectory: true)
    }
    
    private var applicationSupportAppDataDirectoryURL: URL {
        applicationSupportDirectoryURL.appendingPathComponent("AppData", isDirectory: true)
    }
    
    private var applicationSupportDDIDirectoryURL: URL {
        applicationSupportDirectoryURL.appendingPathComponent("DDI", isDirectory: true)
    }
    
    private init(
        fileManager: FileManager = .default,
        directories: ReynardDirectories = .shared
    ) {
        self.fileManager = fileManager
        self.documentsDirectoryURL = directories.documents
        self.applicationSupportDirectoryURL = directories.applicationSupport
    }
    
    func run() {
        migrateAppDataToApplicationSupport()
        migrateDDIToApplicationSupport()
        removeLegacyUserAgentOverride()
    }
    
    // MARK: - Store Migration (0.4.0)
    private func migrateAppDataToApplicationSupport() {
        let sourceURL = documentsAppDataDirectoryURL
        let destinationURL = applicationSupportAppDataDirectoryURL

        do {
            guard try migrateLegacyDirectory(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                prepareStaging: { stagingURL in
                    try self.removeLegacyStoreFolders(in: stagingURL)
                }
            ) else {
                return
            }
        } catch {
            fatalError("AppData migration failed: \(error)")
        }

        guard !fileManager.fileExists(atPath: sourceURL.path) else {
            fatalError("AppData migration failed")
        }
    }

    private func migrateDDIToApplicationSupport() {
        let sourceURL = documentsDDIDirectoryURL
        let destinationURL = applicationSupportDDIDirectoryURL

        do {
            guard try migrateLegacyDirectory(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                prepareStaging: { _ in }
            ) else {
                return
            }
        } catch {
            fatalError("DDI migration failed: \(error)")
        }

        guard !fileManager.fileExists(atPath: sourceURL.path) else {
            fatalError("DDI migration failed")
        }
    }

    private func migrateLegacyDirectory(
        sourceURL: URL,
        destinationURL: URL,
        prepareStaging: (URL) throws -> Void
    ) throws -> Bool {
        let transactionURL = applicationSupportDirectoryURL.appendingPathComponent(
            ".Legacy-\(destinationURL.lastPathComponent)-Migration",
            isDirectory: true
        )
        let stagingURL = transactionURL.appendingPathComponent("staging", isDirectory: true)
        let backupURL = transactionURL.appendingPathComponent("backup", isDirectory: true)
        let journalURL = transactionURL.appendingPathComponent("journal.json", isDirectory: false)

        do {
            try recoverLegacyDirectoryMigration(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                transactionURL: transactionURL
            )
        } catch {
            // A journal we cannot read - corrupt, or written by a newer build -
            // must not fatalError on every launch. The transaction directory is
            // left untouched because it may hold the only copy of the previous
            // destination; defer to a build that understands it.
            return false
        }

        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return true
        }

        var committed = false
        do {
            try fileManager.createDirectory(
                at: applicationSupportDirectoryURL,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: transactionURL,
                withIntermediateDirectories: false
            )
            try fileManager.copyItem(at: sourceURL, to: stagingURL)
            try prepareStaging(stagingURL)

            let destinationExisted = fileManager.fileExists(atPath: destinationURL.path)
            try writeLegacyDirectoryMigrationJournal(
                destinationExisted: destinationExisted,
                phase: .prepared,
                to: journalURL
            )

            if destinationExisted {
                try fileManager.moveItem(at: destinationURL, to: backupURL)
            }
            try fileManager.moveItem(at: stagingURL, to: destinationURL)

            try writeLegacyDirectoryMigrationJournal(
                destinationExisted: destinationExisted,
                phase: .committed,
                to: journalURL
            )
            committed = true

            try finishCommittedLegacyDirectoryMigration(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                transactionURL: transactionURL
            )
        } catch {
            let primaryError = error
            do {
                try recoverLegacyDirectoryMigration(
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    transactionURL: transactionURL
                )
            } catch {
                throw error
            }

            if committed {
                return true
            }
            throw primaryError
        }

        return true
    }

    private func recoverLegacyDirectoryMigration(
        sourceURL: URL,
        destinationURL: URL,
        transactionURL: URL
    ) throws {
        guard fileManager.fileExists(atPath: transactionURL.path) else {
            return
        }

        let journalURL = transactionURL.appendingPathComponent(
            "journal.json",
            isDirectory: false
        )
        guard fileManager.fileExists(atPath: journalURL.path) else {
            try fileManager.removeItem(at: transactionURL)
            return
        }

        let journalData = try Data(contentsOf: journalURL)
        let journal = try JSONDecoder().decode(
            LegacyDirectoryMigrationJournal.self,
            from: journalData
        )
        guard journal.version == LegacyDirectoryMigrationJournal.currentVersion else {
            throw LegacyDirectoryMigrationError.unsupportedJournalVersion
        }

        let backupURL = transactionURL.appendingPathComponent("backup", isDirectory: true)
        switch journal.phase {
        case .prepared:
            if journal.destinationExisted {
                if fileManager.fileExists(atPath: backupURL.path) {
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        try fileManager.removeItem(at: destinationURL)
                    }
                    try fileManager.moveItem(at: backupURL, to: destinationURL)
                } else if !fileManager.fileExists(atPath: destinationURL.path) {
                    throw LegacyDirectoryMigrationError.missingDestination
                }
            } else if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            if fileManager.fileExists(atPath: transactionURL.path) {
                try fileManager.removeItem(at: transactionURL)
            }

        case .committed:
            try finishCommittedLegacyDirectoryMigration(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                transactionURL: transactionURL
            )
        }
    }

    private func finishCommittedLegacyDirectoryMigration(
        sourceURL: URL,
        destinationURL: URL,
        transactionURL: URL
    ) throws {
        guard fileManager.fileExists(atPath: destinationURL.path) else {
            throw LegacyDirectoryMigrationError.missingDestination
        }

        if fileManager.fileExists(atPath: sourceURL.path) {
            try fileManager.removeItem(at: sourceURL)
        }

        let backupURL = transactionURL.appendingPathComponent("backup", isDirectory: true)
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }
        if fileManager.fileExists(atPath: transactionURL.path) {
            try fileManager.removeItem(at: transactionURL)
        }
    }

    private func writeLegacyDirectoryMigrationJournal(
        destinationExisted: Bool,
        phase: LegacyDirectoryMigrationJournal.Phase,
        to journalURL: URL
    ) throws {
        let journal = LegacyDirectoryMigrationJournal(
            version: LegacyDirectoryMigrationJournal.currentVersion,
            destinationExisted: destinationExisted,
            phase: phase
        )
        let data = try JSONEncoder().encode(journal)
        try data.write(to: journalURL, options: .atomic)
    }
    
    private func removeLegacyUserAgentOverride() {
        try? fileManager.removeItem(
            at: documentsDirectoryURL.appendingPathComponent("ua-override.json", isDirectory: false)
        )
    }
    
    private func removeLegacyStoreFolders(in appDataDirectoryURL: URL) throws {
        for folderName in ["TabManagement", "Favicons"] {
            let folderURL = appDataDirectoryURL.appendingPathComponent(folderName, isDirectory: true)
            if fileManager.fileExists(atPath: folderURL.path) {
                try fileManager.removeItem(at: folderURL)
            }
        }
    }
}

//
//  ExternalChangeTests.swift
//  FinvestLens — Persistence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensPersistence

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}

@Suite("External changes / sync")
struct ExternalChangeTests {

    @Test("Detects and adopts an external write to the shared file")
    func externalChange() throws {
        let url = tempURL()
        let doc = try FinvestLensDocument.create(at: url)
        defer { doc.discard(); try? FileManager.default.removeItem(at: url) }
        #expect(doc.hasExternalChanges() == false)

        // Simulate another device writing the shared file.
        let external = Book(baseCurrency: .aud)
        external.addAccount(Account(name: "From other device", type: .bank, commodity: .aud))
        try SQLiteDocumentStore(path: url.path).write(external)

        #expect(doc.hasExternalChanges() == true)

        // Adopt the external version.
        try doc.reloadFromDisk()
        #expect(doc.book.accounts.contains { $0.name == "From other device" })
        #expect(doc.hasExternalChanges() == false)
    }

    @Test("No conflict versions on a plain local file")
    func noConflicts() throws {
        let url = tempURL()
        let doc = try FinvestLensDocument.create(at: url)
        defer { doc.discard(); try? FileManager.default.removeItem(at: url) }
        #expect(doc.unresolvedConflictVersions().isEmpty)
        // Resolving with none present is a no-op that doesn't throw.
        try doc.resolveConflictsKeepingCurrent()
    }
}

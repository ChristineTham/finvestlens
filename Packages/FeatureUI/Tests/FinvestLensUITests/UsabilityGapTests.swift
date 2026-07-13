//
//  UsabilityGapTests.swift
//  FinvestLens — FeatureUI
//
//  Tests for the usability-review additions: account re-parenting helpers,
//  price targets, safe document wrappers, and the recents list.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensReports
import FinvestLensPersistence
@testable import FinvestLensUI

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("finvestlens")
}

@MainActor
@Suite("Usability gaps")
struct UsabilityGapTests {

    @Test("Re-parenting: parentID, validParents excludes self+descendants, move works")
    func reparenting() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }

        let assets = try #require(model.addAccount(name: "Assets", type: .asset))
        let bank = try #require(model.addAccount(name: "Bank", type: .bank, parentID: assets))
        let expenses = try #require(model.addAccount(name: "Expenses", type: .expense))

        #expect(model.parentID(ofAccount: bank) == assets)
        #expect(model.parentID(ofAccount: assets) == nil)

        // Assets can't move under itself or its descendant Bank.
        let candidates = Set(model.validParents(forAccount: assets).map(\.id))
        #expect(!candidates.contains(assets))
        #expect(!candidates.contains(bank))
        #expect(candidates.contains(expenses))
        #expect(!model.moveAccount(assets, under: bank))

        // Moving Bank under Expenses reparents it.
        #expect(model.moveAccount(bank, under: expenses))
        #expect(model.parentID(ofAccount: bank) == expenses)
    }

    @Test("Price targets: set, read back, and remove")
    func priceTargets() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }

        model.addWatchSecurity(exchange: "ASX", ticker: "VAS", name: "Vanguard AUS")
        let vas = try #require(model.pricableSecurities.first { $0.mnemonic == "VAS" })

        model.setPriceTarget(vas, target: 95, direction: .atOrAbove)
        let target = try #require(model.priceTarget(for: vas))
        #expect(target.target == 95)
        #expect(target.direction == .atOrAbove)

        // Re-setting replaces rather than duplicates.
        model.setPriceTarget(vas, target: 90, direction: .atOrBelow)
        #expect(model.priceTargets.count == 1)
        #expect(model.priceTarget(for: vas)?.target == 90)

        model.removePriceTarget(vas)
        #expect(model.priceTarget(for: vas) == nil)
    }

    @Test("openBook surfaces a lock error with Break-Lock recovery, which works")
    func staleLockRecovery() throws {
        let url = tempURL()
        let lockURL = url.deletingPathExtension().appendingPathExtension("lock")
        defer { try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: lockURL) }

        // Create the book, then leave behind a *stale* lock (holder "crashed"
        // long ago — heartbeat far past the 90 s staleness window).
        let first = AppModel()
        try first.newDocument(at: url)
        try first.save()
        first.close()
        let stale = LockHolder(host: "other-mac", user: "someone",
                               instanceID: UUID().uuidString, pid: 99999,
                               acquiredAt: Date(timeIntervalSinceNow: -3600),
                               heartbeatAt: Date(timeIntervalSinceNow: -3600))
        try JSONEncoder().encode(stale).write(to: lockURL)

        // A plain open refuses and surfaces Break-Lock recovery…
        let second = AppModel()
        second.openBook(at: url)
        #expect(!second.isOpen)
        let error = try #require(second.documentError)
        #expect(error.lockedURL == url)

        // …and breaking the stale lock opens the book.
        second.documentError = nil
        second.openBook(at: url, breakStaleLock: true)
        #expect(second.isOpen)
        #expect(second.documentError == nil)
        second.close()
    }

    @Test("openBook auto-saves and closes the previous book")
    func switchingBooksSaves() throws {
        let a = tempURL(), b = tempURL()
        defer { try? FileManager.default.removeItem(at: a)
                try? FileManager.default.removeItem(at: b) }

        let model = AppModel()
        try model.newDocument(at: a)
        _ = model.addAccount(name: "Assets", type: .asset)
        #expect(model.hasUnsavedChanges)

        // Create book B, then switch back to A — the edit must have been saved.
        model.newBook(at: b)
        #expect(model.isOpen)
        model.openBook(at: a)
        #expect(model.accountTree.contains { $0.name == "Assets" })
        model.close()
    }

    @Test("Recents list is most-recent-first, deduplicated, capped at 5")
    func recents() throws {
        UserDefaults.standard.removeObject(forKey: "finvestlens.recentBookPaths")
        var urls: [URL] = []
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        let model = AppModel()
        for _ in 0..<6 {
            let url = tempURL()
            urls.append(url)
            try model.newDocument(at: url)
            model.close()
        }
        // Re-open the 3rd book: it should move to the front, no duplicate.
        model.openBook(at: urls[2])
        model.close()

        #expect(model.recentBooks.count == 5)
        #expect(model.recentBooks.first == urls[2])
        #expect(Set(model.recentBooks).count == model.recentBooks.count)
    }
}

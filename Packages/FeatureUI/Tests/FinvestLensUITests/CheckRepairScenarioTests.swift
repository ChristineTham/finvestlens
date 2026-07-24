//
//  CheckRepairScenarioTests.swift
//  FinvestLens — FeatureUI
//
//  Check & Repair scenarios beyond the basic flow: where each repair lands
//  (Imbalance and Orphan accounts, to the cent), single-split transactions,
//  and the no-findings path.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}

@MainActor
@Suite("Check & Repair scenarios")
struct CheckRepairScenarioTests {

    @Test("An unbalanced transaction gains an Imbalance leg for exactly the residual")
    func unbalancedGainsImbalanceLeg() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        let book = try #require(model.book)
        let broken = Transaction(currency: .aud, datePosted: Date(timeIntervalSince1970: 0),
                                 description: "Short by 12.66")
        broken.addSplit(account: book.account(with: bank)!, value: dec("-52.30"))
        broken.addSplit(account: book.account(with: food)!, value: dec("39.64"))
        book.addTransaction(broken)

        let proposal = try #require(model.cleanupProposal())
        #expect(proposal.unbalancedCount == 1)
        #expect(proposal.orphanCount == 0)
        #expect(proposal.emptyCount == 0)
        #expect(proposal.degenerateCount == 0)
        #expect(!proposal.isEmpty)

        model.applyCleanup()
        #expect(broken.isBalanced)
        #expect(broken.splits.count == 3)
        let imbalance = try #require(book.accounts.first { $0.name == "Imbalance-AUD" })
        let leg = try #require(broken.splits.first { $0.account === imbalance })
        #expect(leg.value == dec("12.66"))
        #expect(model.infoMessage?.contains("balanced 1 transaction(s) via Imbalance") == true)
        #expect(Scrub.check(book).isEmpty)
    }

    @Test("A single-split transaction is degenerate and gets its balancing leg")
    func degenerateGainsBalancingLeg() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let book = try #require(model.book)
        let lonely = Transaction(currency: .aud, datePosted: Date(timeIntervalSince1970: 0),
                                 description: "Half entered")
        lonely.addSplit(account: book.account(with: bank)!, value: dec("100"))
        book.addTransaction(lonely)

        let proposal = try #require(model.cleanupProposal())
        #expect(proposal.degenerateCount == 1)
        #expect(proposal.unbalancedCount == 1)               // one split cannot sum to zero
        #expect(proposal.emptyCount == 0)

        model.applyCleanup()
        #expect(lonely.splits.count == 2)
        #expect(lonely.isBalanced)
        let imbalance = try #require(book.accounts.first { $0.name == "Imbalance-AUD" })
        #expect(lonely.splits.first { $0.account === imbalance }?.value == dec("-100"))
        #expect(Scrub.check(book).isEmpty)
    }

    @Test("An orphan split is filed under Orphan-AUD and the residual under Imbalance-AUD")
    func orphanLandsInOrphanAccount() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let book = try #require(model.book)
        let broken = Transaction(currency: .aud, datePosted: Date(timeIntervalSince1970: 0),
                                 description: "Homeless leg")
        broken.addSplit(account: book.account(with: bank)!, value: dec("100"))
        let homeless = broken.addSplit(Split(account: nil, value: dec("-60")))
        book.addTransaction(broken)

        let proposal = try #require(model.cleanupProposal())
        #expect(proposal.orphanCount == 1)
        #expect(proposal.unbalancedCount == 1)

        model.applyCleanup()
        let orphan = try #require(book.accounts.first { $0.name == "Orphan-AUD" })
        #expect(homeless.account === orphan)
        #expect(homeless.value == dec("-60"))                // reattached, never rewritten
        let imbalance = try #require(book.accounts.first { $0.name == "Imbalance-AUD" })
        #expect(broken.splits.first { $0.account === imbalance }?.value == dec("-40"))
        #expect(broken.isBalanced)
        #expect(Scrub.check(book).isEmpty)
        #expect(orphan.isImbalanceOrOrphan)
        #expect(imbalance.isImbalanceOrOrphan)
    }

    @Test("A clean book proposes nothing, and Check & Repair needs an open book")
    func noFindings() throws {
        let url = tempURL()
        let model = AppModel()

        // No book open: checkAndRepair is a silent no-op.
        model.checkAndRepair()
        #expect(model.infoMessage == nil)
        #expect(model.pendingCleanup == nil)
        #expect(model.cleanupProposal() == nil)

        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        model.addTransfer(from: bank, to: food, amount: dec("25"),
                          date: Date(timeIntervalSince1970: 0), description: "Lunch")

        #expect(model.cleanupProposal() == nil)
        model.checkAndRepair()
        #expect(model.pendingCleanup == nil)
        #expect(model.infoMessage == "No inconsistencies found — the book is clean.")

        // The import note rides along on a proposal when there is one.
        let book = try #require(model.book)
        let stub = Transaction(currency: .aud, datePosted: Date(timeIntervalSince1970: 0),
                               description: "Opening Balance")
        stub.addSplit(account: book.account(with: bank)!, value: 0)
        book.addTransaction(stub)
        let noted = try #require(model.cleanupProposal(importNote: "Imported 2 accounts"))
        #expect(noted.importNote == "Imported 2 accounts")
        #expect(noted.emptyCount == 1)
    }
}

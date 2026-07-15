//
//  SmartImportTests.swift
//  FinvestLens — FeatureUI
//
//  Deterministic core of Smart Import (`FR-AI-07`): dividend verification
//  and fixing, invoice matching with date tolerance, split surgery that
//  preserves reconcile state, and the dual-date behaviour that keeps
//  statement re-imports matching after a date adjustment.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensInterchange
import FinvestLensIntelligence
@testable import FinvestLensUI

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("finvestlens")
}

private func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

@MainActor
@Suite("Smart import — dividends")
struct SmartDividendTests {

    @Test("Statement with booked gross-up verifies; bare deposit offers a fix; nothing matches → noMatch")
    func verdicts() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let dividends = try #require(model.addAccount(name: "Dividends", type: .income))

        let details = DividendStatementDetails(
            securityName: "BHP Group", ticker: "BHP",
            paymentDate: utcDate(2026, 6, 12),
            frankedAmount: 412.30, unfrankedAmount: 0,
            frankingCredits: 176.70, netPayment: 412.30
        )

        // Nothing in the register yet.
        #expect(model.checkDividendStatement(details).verdict == .noMatch)

        // A bare deposit (bank posts a couple of days later, no gross-up).
        let bare = try model.addTransaction(
            date: utcDate(2026, 6, 15), description: "BHP GROUP DIV", currency: .aud,
            splits: [SplitInput(accountID: bank, value: 412.30),
                     SplitInput(accountID: dividends, value: -412.30)]
        )
        let check = model.checkDividendStatement(details)
        #expect(check.verdict == .missingFrankingCredits)
        #expect(check.transactionID == bare)
        #expect(check.foundFrankingCredits == 0)

        // Fix it — the cash split keeps its reconcile state, the gross-up
        // appears, and the payment date is adopted with the bank date kept.
        let book = try #require(model.book)
        let transaction = try #require(book.transaction(with: bare))
        let cash = try #require(transaction.splits.first { $0.value == Decimal(string: "412.30") })
        cash.reconcileState = .cleared

        try model.applyDividendFix(details, to: bare)
        #expect(transaction.isBalanced)
        #expect(transaction.splits.count == 4)  // cash + franked + credits pair
        #expect(cash.reconcileState == .cleared)
        #expect(transaction.datePosted == utcDate(2026, 6, 12))
        #expect(transaction.statementDate == utcDate(2026, 6, 15))
        #expect(transaction.tags.contains("dividend"))

        // Now it verifies.
        let recheck = model.checkDividendStatement(details)
        #expect(recheck.verdict == .verified)
        #expect(recheck.foundFrankingCredits == Decimal(string: "176.70"))
    }
}

@MainActor
@Suite("Smart import — invoices")
struct SmartInvoiceTests {

    private func makeAnalysis(date: Date?, groceries: GncGUID?) -> InvoiceAnalysis {
        InvoiceAnalysis(
            vendor: "Officeworks", date: date,
            total: Decimal(string: "809.75")!,
            lineItems: [
                InvoiceLineItem(itemDescription: "Printer", amount: Decimal(string: "499.00")!,
                                suggestedCategoryID: groceries),
                InvoiceLineItem(itemDescription: "Paper", amount: Decimal(string: "21.75")!,
                                suggestedCategoryID: groceries),
                InvoiceLineItem(itemDescription: "Chair", amount: Decimal(string: "289.00")!,
                                suggestedCategoryID: nil),
            ]
        )
    }

    @Test("Bank-posted transaction a few days after the invoice matches; outside the window it doesn't")
    func matching() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let shopping = try #require(model.addAccount(name: "Shopping", type: .expense))

        _ = try model.addTransaction(
            date: utcDate(2026, 6, 6), description: "OFFICEWORKS SYDNEY", currency: .aud,
            splits: [SplitInput(accountID: bank, value: Decimal(string: "-809.75")!),
                     SplitInput(accountID: shopping, value: Decimal(string: "809.75")!)]
        )

        // Invoice dated 3 June; bank posted 6 June — matches, proposes 3 June.
        let analysis = makeAnalysis(date: utcDate(2026, 6, 3), groceries: shopping)
        let match = try #require(model.findInvoiceMatch(for: analysis))
        #expect(match.transactionDescription == "OFFICEWORKS SYDNEY")
        #expect(match.proposedDate == utcDate(2026, 6, 3))

        // An invoice dated a month earlier is out of the window.
        let stale = makeAnalysis(date: utcDate(2026, 5, 1), groceries: shopping)
        #expect(model.findInvoiceMatch(for: stale) == nil)
    }

    @Test("Applying an invoice splits the counter leg, keeps the funding split's state, and adopts the invoice date")
    func applySplit() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let shopping = try #require(model.addAccount(name: "Shopping", type: .expense))
        let office = try #require(model.addAccount(name: "Home Office", type: .expense))

        let id = try model.addTransaction(
            date: utcDate(2026, 6, 6), description: "OFFICEWORKS SYDNEY", currency: .aud,
            splits: [SplitInput(accountID: bank, value: Decimal(string: "-809.75")!),
                     SplitInput(accountID: shopping, value: Decimal(string: "809.75")!)]
        )
        let book = try #require(model.book)
        let transaction = try #require(book.transaction(with: id))
        let funding = try #require(transaction.splits.first { $0.value < 0 })
        funding.reconcileState = .cleared

        var analysis = makeAnalysis(date: utcDate(2026, 6, 3), groceries: office)
        // Chair (no suggestion) should fall back to the previous counter
        // account (Shopping).
        try model.applyInvoiceSplit(analysis, to: id, adjustDate: true)

        #expect(transaction.isBalanced)
        #expect(funding.reconcileState == .cleared)
        #expect(funding.value == Decimal(string: "-809.75"))
        #expect(transaction.datePosted == utcDate(2026, 6, 3))
        #expect(transaction.statementDate == utcDate(2026, 6, 6))

        let officeAccount = try #require(book.account(with: office))
        let shoppingAccount = try #require(book.account(with: shopping))
        #expect(book.splits(for: officeAccount).map(\.value).sorted()
                == [Decimal(string: "21.75")!, Decimal(string: "499.00")!])
        #expect(book.splits(for: shoppingAccount).map(\.value) == [Decimal(string: "289.00")!])

        // Re-importing the bank statement (dated 6 June) still recognises the
        // transaction via its statement date — no duplicate is created.
        let staged = [StagedTransaction(date: utcDate(2026, 6, 6),
                                        amount: Decimal(string: "-809.75")!,
                                        payee: "OFFICEWORKS SYDNEY")]
        let results = model.matchStaged(staged, intoAccountID: bank)
        #expect(results.first?.isDuplicate == true)

        // Idempotent-ish: a second apply re-splits without stacking dates.
        analysis.lineItems[2].suggestedCategoryID = office
        try model.applyInvoiceSplit(analysis, to: id, adjustDate: true)
        #expect(transaction.statementDate == utcDate(2026, 6, 6))
        #expect(transaction.isBalanced)
    }

    @Test("Line-item shortfall against the total posts an adjustment split")
    func residual() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let shopping = try #require(model.addAccount(name: "Shopping", type: .expense))
        let id = try model.addTransaction(
            date: utcDate(2026, 6, 6), description: "SHOP", currency: .aud,
            splits: [SplitInput(accountID: bank, value: -100),
                     SplitInput(accountID: shopping, value: 100)]
        )

        let analysis = InvoiceAnalysis(
            vendor: "Shop", date: utcDate(2026, 6, 5), total: 100,
            lineItems: [InvoiceLineItem(itemDescription: "Widget", amount: 90,
                                        suggestedCategoryID: shopping)]
        )
        try model.applyInvoiceSplit(analysis, to: id, adjustDate: false)
        let book = try #require(model.book)
        let transaction = try #require(book.transaction(with: id))
        #expect(transaction.isBalanced)
        #expect(transaction.splits.count == 3)  // funding + widget + adjustment
        #expect(transaction.splits.contains { $0.memo == "Invoice adjustment" && $0.value == 10 })
        // No date change requested → no statement date stored.
        #expect(transaction.statementDate == nil)
        #expect(transaction.datePosted == utcDate(2026, 6, 6))
    }
}

@MainActor
@Suite("Smart import — dual dates persist")
struct StatementDatePersistenceTests {

    @Test("statementDate survives save and reopen in the native document")
    func roundTrip() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let shopping = try #require(model.addAccount(name: "Shopping", type: .expense))
        let id = try model.addTransaction(
            date: utcDate(2026, 6, 3), description: "SHOP", currency: .aud,
            splits: [SplitInput(accountID: bank, value: -50),
                     SplitInput(accountID: shopping, value: 50)]
        )
        let book = try #require(model.book)
        try #require(book.transaction(with: id)).statementDate = utcDate(2026, 6, 6)
        model.refreshAfterChange()
        try model.save()
        model.close()

        let reopened = AppModel()
        try await reopened.open(at: url)
        defer { reopened.close() }
        let transaction = try #require(reopened.book?.transaction(with: id))
        #expect(transaction.statementDate == utcDate(2026, 6, 6))
        #expect(transaction.datePosted == utcDate(2026, 6, 3))
    }
}

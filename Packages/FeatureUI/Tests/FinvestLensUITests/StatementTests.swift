//
//  StatementTests.swift
//  FinvestLens — FeatureUI
//
//  The statement presentation layer arranges verified figures; these tests
//  enforce that it never moves a dollar. Identities pinned: face section
//  totals ≡ the sum of the face captions; note totals tie to their face
//  lines; materiality folding conserves sums; chain collapse never produces
//  a path-like caption; ASC 274 ordering holds.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}

@MainActor
private struct Fixture {
    let model = AppModel()
    let url: URL

    /// A small but structured book: grouped assets with a deep income tree
    /// (the `Income:Distributions:VGAD:Distribution` shape from the brief),
    /// many small expense accounts (to exercise materiality folding), a
    /// credit card and a loan (maturity ordering), and an imbalance account.
    init() throws {
        url = tempURL()
        try model.newDocument(at: url)
        let book = model.book!

        func add(_ name: String, _ type: AccountType, under parent: Account) -> Account {
            let account = Account(name: name, type: type, commodity: .aud)
            parent.addChild(account)
            return account
        }
        let root = book.rootAccount
        let assets = add("Assets", .asset, under: root)
        let income = add("Income", .income, under: root)
        let expenses = add("Expenses", .expense, under: root)
        let liabilities = add("Liabilities", .liability, under: root)

        let cash = add("Everyday", .bank, under: assets)
        let property = add("Home", .asset, under: assets)
        let distributions = add("Distributions", .income, under: income)
        let vgad = add("VGAD", .income, under: distributions)
        let vgadLeaf = add("Distribution", .income, under: vgad)
        let vas = add("VAS", .income, under: distributions)
        let vasLeaf = add("Distribution", .income, under: vas)
        let salary = add("Salary", .income, under: income)
        let card = add("Visa", .credit, under: liabilities)
        let loan = add("Mortgage", .liability, under: liabilities)
        let imbalance = add("Imbalance-AUD", .bank, under: root)

        // Ten small expense accounts + one big one → folding has work to do.
        let big = add("Groceries", .expense, under: expenses)
        var smalls: [Account] = []
        for index in 1...10 { smalls.append(add("Tiny\(index)", .expense, under: expenses)) }

        model.refreshAll()
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        func txn(_ amount: Decimal, from: Account, to: Account, _ desc: String) throws {
            _ = try model.addTransaction(date: date, description: desc, currency: .aud,
                splits: [SplitInput(accountID: from.guid, value: -amount),
                         SplitInput(accountID: to.guid, value: amount)])
        }
        try txn(5_000, from: salary, to: cash, "Pay")            // income 5000
        try txn(800, from: vgadLeaf, to: cash, "VGAD dist")      // deep chain
        try txn(200, from: vasLeaf, to: cash, "VAS dist")
        try txn(2_000, from: cash, to: big, "Food")
        for small in smalls { try txn(3, from: cash, to: small, "Tiny") }
        try txn(20_000, from: card, to: cash, "Cash advance")    // material card balance
        try txn(250_000, from: loan, to: property, "House")
        try txn(50, from: imbalance, to: cash, "Unmatched")
    }

    func tearDown() {
        model.close()
        try? FileManager.default.removeItem(at: url)
    }
}

@MainActor
@Suite("Annual-report statements")
struct StatementTests {

    private func sum(_ items: [StatementItem], column: Int) -> Decimal {
        items.filter { $0.role == .line }
            .reduce(Decimal(0)) { $0 + ($1.amounts[column] ?? 0) }
    }

    @Test("Face captions add to the engine's section totals")
    func faceTies() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let statement = try #require(f.model.financialPositionStatement(asOf: .now))
        let sheet = try #require(f.model.balanceSheet(asOf: .now))

        let assets = try #require(statement.sections.first { $0.title == "Assets" })
        #expect(sum(assets.items, column: 0) == sheet.totalAssets)
        #expect(assets.totalAmounts[0] == sheet.totalAssets)

        let liabilities = try #require(statement.sections.first { $0.title == "Liabilities" })
        #expect(sum(liabilities.items, column: 0) == sheet.totalLiabilities)

        // Net worth = A − L, and the composition note ties to the same figure
        // through the equity view (the sheet balances).
        let net = try #require(statement.grandTotal)
        #expect(net.amounts[0] == sheet.totalAssets - sheet.totalLiabilities)
        let composition = try #require(statement.notes.first { $0.title == "Composition of net worth" })
        #expect(composition.totalAmounts[0] == sheet.totalAssets - sheet.totalLiabilities)
        // Single-currency fixture: no translation line, and the sheet balances.
        #expect(!composition.rows.contains { $0.label.hasPrefix("Currency translation") })
        #expect(sheet.isBalanced)
    }

    @Test("Note totals tie to their face lines; folding conserves sums")
    func notesTie() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let date = Date.now
        let statement = try #require(f.model.incomeStatementStatement(
            from: .distantPast, to: date, periodLabel: "All time"))
        let engine = try #require(f.model.incomeStatement(from: .distantPast, to: date))

        for section in statement.sections {
            #expect(sum(section.items, column: 0) == section.totalAmounts[0] ?? 0)
            for item in section.items where item.noteRef != nil {
                let note = try #require(statement.notes.first { $0.number == item.noteRef })
                #expect(note.totalAmounts[0] == item.amounts[0],
                        "note \(note.number) must tie to face line \(item.caption)")
                // And the note's own leaf rows add to its total.
                let leafSum = note.rows.filter { row in
                    // Depth-0 rows are the note's top level; deeper rows are
                    // their breakdown — sum only the top level.
                    row.depth == 0
                }.reduce(Decimal(0)) { $0 + ($1.amounts[0] ?? 0) }
                #expect(leafSum == note.totalAmounts[0] ?? 0)
            }
        }
        let income = try #require(statement.sections.first { $0.title == "Income" })
        #expect(income.totalAmounts[0] == engine.totalIncome)
        let expenses = try #require(statement.sections.first { $0.title == "Expenses" })
        #expect(expenses.totalAmounts[0] == engine.totalExpenses)
        #expect(statement.grandTotal?.amounts[0] == engine.netIncome)
    }

    @Test("Materiality folds the ten tiny expenses into Other, with a note")
    func materialityFolding() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let statement = try #require(f.model.incomeStatementStatement(
            from: .distantPast, to: .now, periodLabel: "All time"))
        let expenses = try #require(statement.sections.first { $0.title == "Expenses" })

        let other = try #require(expenses.items.first { $0.caption.hasPrefix("Other") })
        #expect(other.amounts[0] == 30)   // 10 × $3
        let note = try #require(statement.notes.first { $0.number == other.noteRef })
        #expect(note.rows.count == 10)
        #expect(expenses.items.contains { $0.caption == "Groceries" })
        #expect(!expenses.items.contains { $0.caption.hasPrefix("Tiny") })
    }

    @Test("Chain collapse: no path-like captions, VGAD keeps its name")
    func chainCollapse() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let statement = try #require(f.model.incomeStatementStatement(
            from: .distantPast, to: .now, periodLabel: "All time"))

        // The face shows the user's top-level groups.
        let income = try #require(statement.sections.first { $0.title == "Income" })
        #expect(income.items.contains { $0.caption == "Distributions" })
        #expect(income.items.contains { $0.caption == "Salary" })

        // Nowhere — face or notes — does a colon path or a generic leaf
        // swallow a fund name: VGAD/VAS survive, "Distribution" disappears.
        let allLabels = statement.sections.flatMap { $0.items.map(\.caption) }
            + statement.notes.flatMap { $0.rows.map(\.label) }
        #expect(allLabels.allSatisfy { !$0.contains(":") })
        #expect(allLabels.contains("VGAD"))
        #expect(allLabels.contains("VAS"))
        #expect(!allLabels.contains("Distribution"))
    }

    @Test("ASC 274 ordering: liquidity for assets, maturity for liabilities")
    func ordering() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let statement = try #require(f.model.financialPositionStatement(asOf: .now))

        let assets = try #require(statement.sections.first { $0.title == "Assets" })
        let captions = assets.items.filter { $0.role == .line }.map(\.caption)
        // Cash (bank) before the home (plain asset).
        let cashIndex = try #require(captions.firstIndex(of: "Everyday"))
        let homeIndex = try #require(captions.firstIndex(of: "Home"))
        #expect(cashIndex < homeIndex)

        let liabilities = try #require(statement.sections.first { $0.title == "Liabilities" })
        let liabilityCaptions = liabilities.items.filter { $0.role == .line }.map(\.caption)
        let cardIndex = try #require(liabilityCaptions.firstIndex(of: "Visa"))
        let loanIndex = try #require(liabilityCaptions.firstIndex(of: "Mortgage"))
        #expect(cardIndex < loanIndex)
    }

    @Test("Imbalance accounts read as Uncategorised on the face")
    func imbalanceRename() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let statement = try #require(f.model.financialPositionStatement(asOf: .now))
        let labels = statement.sections.flatMap { $0.items.map(\.caption) }
        #expect(labels.contains("Uncategorised"))
        #expect(!labels.contains { $0.hasPrefix("Imbalance") })
    }

    @Test("Trial balance statement: sections tie, and the books balance")
    func trialBalanceStatement() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let statement = try #require(f.model.trialBalanceStatement(asOf: .now))
        let engine = try #require(f.model.trialBalance(asOf: .now))

        #expect(statement.columns == ["Debit", "Credit"])

        // Every section's caption rows add to its totals, per column.
        for section in statement.sections {
            for column in 0..<2 {
                let captionSum = section.items.filter { $0.role == .line }
                    .reduce(Decimal(0)) { $0 + ($1.amounts[column] ?? 0) }
                #expect(captionSum == section.totalAmounts[column] ?? 0,
                        "section \(section.title) column \(column)")
            }
        }

        // All sections together carry every dollar of the engine's columns.
        var debits = Decimal(0), credits = Decimal(0)
        for section in statement.sections {
            debits += section.totalAmounts[0] ?? 0
            credits += section.totalAmounts[1] ?? 0
        }
        #expect(debits == engine.totalDebits)
        #expect(credits == engine.totalCredits)

        // And the report's whole point: the grand total balances.
        let grand = try #require(statement.grandTotal)
        #expect(grand.amounts[0] == grand.amounts[1])
        #expect(grand.amounts[0] == engine.totalDebits)

        // Grouped by category, not a flat account dump: the fixture's assets
        // and liabilities land in their own sections.
        let titles = statement.sections.map(\.title)
        #expect(titles.contains("Assets"))
        #expect(titles.contains("Liabilities"))
    }

    @Test("Changes in net worth: opening + surplus + valuation = closing")
    func changesInNetWorth() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let to = Date.now
        let statement = try #require(f.model.changesInNetWorthStatement(
            from: .distantPast, to: to, periodLabel: "All time"))
        let section = try #require(statement.sections.first)

        let lines = section.items.filter { $0.role == .line }
        let total = lines.reduce(Decimal(0)) { $0 + ($1.amounts[0] ?? 0) }
        #expect(total == section.totalAmounts[0] ?? 0)

        let closing = try #require(f.model.balanceSheet(asOf: to))
        #expect(section.totalAmounts[0] == closing.totalAssets - closing.totalLiabilities)
    }
}

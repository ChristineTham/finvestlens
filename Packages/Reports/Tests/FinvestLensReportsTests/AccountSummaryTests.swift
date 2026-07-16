//
//  AccountSummaryTests.swift
//  FinvestLens — Reports
//
//  The depth limit is the report, and the rule that makes it trustworthy is
//  that cutting the tree never loses money: every depth sums to the same
//  totals, and those totals are the balance sheet's.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensReports

@Suite("Account summary")
struct AccountSummaryTests {

    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(n) * 86_400) }

    /// A three-deep asset tree under a placeholder, so depth actually cuts
    /// something: Assets ▸ Banks ▸ {Everyday, Savings ▸ Holiday}.
    private func makeBook() -> Book {
        let book = Book(baseCurrency: .aud)
        let assets = Account(name: "Assets", type: .asset, commodity: .aud)
        assets.isPlaceholder = true
        _ = book.addAccount(assets)
        let banks = Account(name: "Banks", type: .asset, commodity: .aud)
        banks.isPlaceholder = true
        _ = book.addAccount(banks, under: assets)
        let everyday = book.addAccount(Account(name: "Everyday", type: .bank, commodity: .aud),
                                       under: banks)
        let savings = book.addAccount(Account(name: "Savings", type: .bank, commodity: .aud),
                                      under: banks)
        let holiday = book.addAccount(Account(name: "Holiday", type: .bank, commodity: .aud),
                                      under: savings)
        let salary = book.addAccount(Account(name: "Salary", type: .income, commodity: .aud))

        func post(_ to: Account, _ amount: Decimal, day n: Int) {
            let txn = Transaction(currency: .aud, datePosted: day(n), description: "t")
            txn.addSplit(account: to, value: amount)
            txn.addSplit(account: salary, value: -amount)
            book.addTransaction(txn)
        }
        post(everyday, 1000, day: 0)
        post(savings, 500, day: 1)
        post(holiday, 250, day: 2)
        return book
    }

    private func assets(_ report: AccountSummaryReport) -> AccountSummarySection {
        report.sections.first { $0.title == "Assets" }!
    }

    /// The identity: the section total is the same number at every depth.
    @Test("Every depth sums to the same totals")
    func depthsAgree() {
        let book = makeBook()
        let totals = (1...4).map {
            assets(FinancialReports.accountSummary(book, asOf: day(10), currency: .aud,
                                                   depthLimit: $0)).total
        }
        #expect(totals == [1750, 1750, 1750, 1750])
        // …and they are the balance sheet's total.
        let sheet = FinancialReports.balanceSheet(book, asOf: day(10), currency: .aud)
        #expect(totals[0] == sheet.totalAssets)
    }

    /// At the limit an account absorbs everything beneath it.
    @Test("An account at the limit rolls its subtree up")
    func rollsUp() throws {
        let book = makeBook()
        let report = FinancialReports.accountSummary(book, asOf: day(10), currency: .aud,
                                                     depthLimit: 3)
        let section = assets(report)
        // Depth 3 is Everyday/Savings; Holiday (depth 4) rolls into Savings.
        let savings = try #require(section.rows.first { $0.name == "Savings" })
        #expect(savings.balance == 750)                // 500 + rolled 250
        #expect(!section.rows.contains { $0.name == "Holiday" })

        // One level deeper, Savings shows its own money and Holiday its own.
        let deeper = assets(FinancialReports.accountSummary(book, asOf: day(10), currency: .aud,
                                                            depthLimit: 4))
        #expect(deeper.rows.first { $0.name == "Savings" }?.balance == 500)
        #expect(deeper.rows.first { $0.name == "Holiday" }?.balance == 250)
    }

    @Test("A placeholder shows structure, not money of its own")
    func placeholders() throws {
        let book = makeBook()
        let report = FinancialReports.accountSummary(book, asOf: day(10), currency: .aud,
                                                     depthLimit: 4)
        let banks = try #require(assets(report).rows.first { $0.name == "Banks" })
        #expect(banks.balance == 0)     // its children carry the money
        #expect(banks.depth == 2)
        // But cut at its level, it answers for the subtree.
        let cut = FinancialReports.accountSummary(book, asOf: day(10), currency: .aud,
                                                  depthLimit: 2)
        #expect(assets(cut).rows.first { $0.name == "Banks" }?.balance == 1750)
    }

    @Test("Rows carry their depth, parents before children")
    func ordering() {
        let book = makeBook()
        let section = assets(FinancialReports.accountSummary(book, asOf: day(10), currency: .aud,
                                                             depthLimit: 4))
        let names = section.rows.map(\.name)
        #expect(names == ["Assets", "Banks", "Everyday", "Savings", "Holiday"])
        #expect(section.rows.map(\.depth) == [1, 2, 3, 3, 4])
    }

    /// Income balances here are lifetime-to-date — what the account holds as of
    /// the date, which for income is everything it has recorded.
    @Test("Income reads lifetime-to-date, presentation-signed")
    func incomeSection() throws {
        let book = makeBook()
        let report = FinancialReports.accountSummary(book, asOf: day(10), currency: .aud,
                                                     depthLimit: 2)
        let income = try #require(report.sections.first { $0.title == "Income" })
        #expect(income.total == 1750)
        #expect(income.rows.first { $0.name == "Salary" }?.balance == 1750)
    }

    @Test("An empty subtree is pruned, not shown as a page of zeroes")
    func pruning() {
        let book = makeBook()
        let unused = Account(name: "Unused", type: .asset, commodity: .aud)
        unused.isPlaceholder = true
        _ = book.addAccount(unused)
        _ = book.addAccount(Account(name: "Dormant", type: .bank, commodity: .aud), under: unused)

        let section = assets(FinancialReports.accountSummary(book, asOf: day(10), currency: .aud,
                                                             depthLimit: 4))
        #expect(!section.rows.contains { $0.name == "Unused" })
        #expect(!section.rows.contains { $0.name == "Dormant" })
    }
}

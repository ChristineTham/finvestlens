//
//  TrialBalanceTests.swift
//  FinvestLens — Reports
//
//  The trial balance's whole claim is that debits equal credits. In one
//  currency that follows from double entry; valued at market it fails by
//  exactly the unrealised gain, which the report prints as an adjustment
//  rather than hiding. So the tests pin two things: the identity, and that
//  the adjustment is the *right* number, not merely whatever plugs the gap.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensReports

@Suite("Trial balance")
struct TrialBalanceTests {

    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(n) * 86_400) }

    /// One currency, several account types, no prices — the book where double
    /// entry alone must balance the columns.
    private func plainBook() -> Book {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let card = book.addAccount(Account(name: "Card", type: .credit, commodity: .aud))
        let salary = book.addAccount(Account(name: "Salary", type: .income, commodity: .aud))
        let rent = book.addAccount(Account(name: "Rent", type: .expense, commodity: .aud))
        let opening = book.addAccount(Account(name: "Opening", type: .equity, commodity: .aud))

        func post(_ from: Account, _ to: Account, _ amount: Decimal, day n: Int) {
            let txn = Transaction(currency: .aud, datePosted: day(n), description: "t")
            txn.addSplit(account: to, value: amount)
            txn.addSplit(account: from, value: -amount)
            book.addTransaction(txn)
        }
        post(opening, bank, 1000, day: 0)
        post(salary, bank, 5000, day: 1)
        post(bank, rent, 2000, day: 2)
        post(card, rent, 300, day: 3)
        return book
    }

    @Test("One currency balances by double entry, with no adjustment")
    func plainBookBalances() {
        let report = FinancialReports.trialBalance(plainBook(), asOf: day(10), currency: .aud)
        #expect(report.isBalanced)
        #expect(report.unrealisedAdjustment == 0)
        #expect(report.totalDebits == report.totalCredits)
        // 4000 bank + 2300 rent = 6300 of debits.
        #expect(report.totalDebits == 6300)
    }

    @Test("Debits sit with debit-balance accounts, credits with credit")
    func columnsAreRight() throws {
        let report = FinancialReports.trialBalance(plainBook(), asOf: day(10), currency: .aud)
        func row(_ name: String) -> TrialBalanceRow? { report.rows.first { $0.name == name } }

        #expect(try #require(row("Bank")).debit == 4000)       // 1000 + 5000 − 2000
        #expect(try #require(row("Rent")).debit == 2300)
        #expect(try #require(row("Salary")).credit == 5000)
        #expect(try #require(row("Card")).credit == 300)
        #expect(try #require(row("Opening")).credit == 1000)
        // Exactly one column each.
        #expect(report.rows.allSatisfy { ($0.debit == nil) != ($0.credit == nil) })
    }

    /// The adjustment must be the unrealised gain, not just a plug: 10 shares
    /// bought at 40, priced at 45.50, is exactly 55 of gain.
    @Test("Market valuation shows up as the unrealised adjustment")
    func unrealisedGainIsMeasured() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let opening = book.addAccount(Account(name: "Opening", type: .equity, commodity: .aud))
        let bhpCommodity = Commodity(namespace: .security("ASX"), mnemonic: "BHP",
                                     fullName: "BHP", smallestFraction: 10000)
        let bhp = book.addAccount(Account(name: "BHP", type: .stock, commodity: bhpCommodity))

        let fund = Transaction(currency: .aud, datePosted: day(0), description: "fund")
        fund.addSplit(account: bank, value: 1000)
        fund.addSplit(account: opening, value: -1000)
        book.addTransaction(fund)

        let buy = Transaction(currency: .aud, datePosted: day(1), description: "buy")
        buy.addSplit(Split(account: bhp, value: 400, quantity: 10))
        buy.addSplit(account: bank, value: -400)
        book.addTransaction(buy)

        book.addPrice(Price(commodity: bhpCommodity, currency: .aud, date: day(2),
                            value: dec("45.50")))

        let report = FinancialReports.trialBalance(book, asOf: day(3), currency: .aud)
        #expect(report.isBalanced)
        // 10 × 45.50 = 455 at market against 400 at cost.
        #expect(report.unrealisedAdjustment == 55)
        #expect(report.rows.first { $0.name == "BHP" }?.debit == 455)
    }

    @Test("A zero-balance account is not listed")
    func zeroBalancesAreOmitted() {
        let book = plainBook()
        _ = book.addAccount(Account(name: "Dormant", type: .bank, commodity: .aud))
        let report = FinancialReports.trialBalance(book, asOf: day(10), currency: .aud)
        #expect(!report.rows.contains { $0.name == "Dormant" })
    }

    @Test("Placeholders hold no balances and are not listed")
    func placeholdersAreOmitted() {
        let book = plainBook()
        let holder = Account(name: "Assets", type: .asset, commodity: .aud)
        holder.isPlaceholder = true
        _ = book.addAccount(holder)
        let report = FinancialReports.trialBalance(book, asOf: day(10), currency: .aud)
        #expect(!report.rows.contains { $0.name == "Assets" })
    }

    /// As-of is a real cutoff: the same book earlier shows earlier balances,
    /// and still balances.
    @Test("An earlier as-of balances with the earlier figures")
    func asOfCutoff() throws {
        let report = FinancialReports.trialBalance(plainBook(), asOf: day(1), currency: .aud)
        #expect(report.isBalanced)
        #expect(try #require(report.rows.first { $0.name == "Bank" }).debit == 6000)
        #expect(!report.rows.contains { $0.name == "Rent" })
    }

    @Test("An empty book is trivially balanced")
    func emptyBook() {
        let report = FinancialReports.trialBalance(Book(baseCurrency: .aud),
                                                   asOf: day(0), currency: .aud)
        #expect(report.rows.isEmpty)
        #expect(report.isBalanced)
        #expect(report.unrealisedAdjustment == 0)
    }
}

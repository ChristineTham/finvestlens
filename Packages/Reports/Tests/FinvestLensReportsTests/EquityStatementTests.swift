//
//  EquityStatementTests.swift
//  FinvestLens — Reports
//
//  The equity statement is the bridge between two balance sheets, and its
//  unrealised term is a residual — so the tests have to prove the residual is
//  *the valuation change* and not a rug for errors: exactly zero when every
//  price stands still, exactly the price move when one moves.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensReports

@Suite("Equity statement")
struct EquityStatementTests {

    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(n) * 86_400) }

    /// Opening balance before the period; salary, rent and an owner draw inside
    /// it. No prices anywhere, so the unrealised term has nothing to say.
    private func plainBook() -> (Book, bank: Account) {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let salary = book.addAccount(Account(name: "Salary", type: .income, commodity: .aud))
        let rent = book.addAccount(Account(name: "Rent", type: .expense, commodity: .aud))
        let opening = book.addAccount(Account(name: "Opening", type: .equity, commodity: .aud))
        let drawings = book.addAccount(Account(name: "Drawings", type: .equity, commodity: .aud))

        func post(_ from: Account, _ to: Account, _ amount: Decimal, day n: Int) {
            let txn = Transaction(currency: .aud, datePosted: day(n), description: "t")
            txn.addSplit(account: to, value: amount)
            txn.addSplit(account: from, value: -amount)
            book.addTransaction(txn)
        }
        post(opening, bank, 10_000, day: 0)    // before the period
        post(salary, bank, 5_000, day: 12)     // inside
        post(bank, rent, 2_000, day: 14)       // inside
        post(bank, drawings, 500, day: 16)     // owner takes money out
        return (book, bank)
    }

    @Test("Opening + net income + contributions − withdrawals = closing")
    func theBridgeHolds() {
        let (book, _) = plainBook()
        let statement = FinancialReports.equityStatement(book, from: day(10), to: day(20),
                                                         currency: .aud)
        #expect(statement.isConsistent)
        #expect(statement.openingCapital == 10_000)
        #expect(statement.netIncome == 3_000)          // 5000 − 2000
        #expect(statement.contributions == 0)
        #expect(statement.withdrawals == 500)
        #expect(statement.unrealisedChange == 0)       // no price moved
        #expect(statement.closingCapital == 12_500)    // 10000 + 5000 − 2000 − 500
    }

    /// A contribution during the period is capital in, not income.
    @Test("Money the owner puts in is a contribution, not income")
    func contributionsAreNotIncome() {
        let (book, bank) = plainBook()
        let equity = book.accounts.first { $0.name == "Opening" }!
        let txn = Transaction(currency: .aud, datePosted: day(15), description: "top-up")
        txn.addSplit(account: bank, value: 3_000)
        txn.addSplit(account: equity, value: -3_000)
        book.addTransaction(txn)

        let statement = FinancialReports.equityStatement(book, from: day(10), to: day(20),
                                                         currency: .aud)
        #expect(statement.contributions == 3_000)
        #expect(statement.netIncome == 3_000)          // unchanged
        #expect(statement.isConsistent)
        #expect(statement.closingCapital == 15_500)
    }

    /// The residual must be the valuation change: a holding bought inside the
    /// period and priced up by 55 makes the term read exactly 55.
    @Test("A price move is exactly the unrealised term")
    func unrealisedIsThePriceMove() {
        let (book, bank) = plainBook()
        let bhpCommodity = Commodity(namespace: .security("ASX"), mnemonic: "BHP",
                                     fullName: "BHP", smallestFraction: 10000)
        let bhp = book.addAccount(Account(name: "BHP", type: .stock, commodity: bhpCommodity))

        let buy = Transaction(currency: .aud, datePosted: day(13), description: "buy")
        buy.addSplit(Split(account: bhp, value: 400, quantity: 10))
        buy.addSplit(account: bank, value: -400)
        book.addTransaction(buy)
        book.addPrice(Price(commodity: bhpCommodity, currency: .aud, date: day(18),
                            value: dec("45.50")))

        let statement = FinancialReports.equityStatement(book, from: day(10), to: day(20),
                                                         currency: .aud)
        #expect(statement.unrealisedChange == 55)      // 455 market − 400 cost
        #expect(statement.isConsistent)
    }

    /// A posting dated on the period's first day belongs to the period — the
    /// opening is the world strictly before it.
    @Test("The opening excludes the period's own first day")
    func openingIsExclusive() {
        let (book, _) = plainBook()
        let statement = FinancialReports.equityStatement(book, from: day(12), to: day(20),
                                                         currency: .aud)
        // The day-12 salary is period income, not opening capital.
        #expect(statement.openingCapital == 10_000)
        #expect(statement.netIncome == 3_000)
        #expect(statement.isConsistent)
    }

    @Test("An empty period bridges opening to itself")
    func emptyPeriod() {
        let (book, _) = plainBook()
        let statement = FinancialReports.equityStatement(book, from: day(2), to: day(5),
                                                         currency: .aud)
        #expect(statement.openingCapital == 10_000)
        #expect(statement.closingCapital == 10_000)
        #expect(statement.netIncome == 0)
        #expect(statement.unrealisedChange == 0)
        #expect(statement.isConsistent)
    }
}

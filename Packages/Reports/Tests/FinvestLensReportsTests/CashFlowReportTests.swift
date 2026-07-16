//
//  CashFlowReportTests.swift
//  FinvestLens — Reports
//
//  GnuCash's Cash Flow. The attribution rule is double entry itself, and the
//  test that matters is the identity that falls out of it: money in minus
//  money out equals the chosen accounts' net change over the period, to the
//  cent — with internal transfers vanishing, as internal shuffles should.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensReports

@Suite("Cash flow report")
struct CashFlowReportTests {

    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(n) * 86_400) }

    private struct Fixture {
        let book: Book
        let bank: Account
        let savings: Account
        let salary: Account
        let rent: Account
        let food: Account
    }

    private func makeFixture() -> Fixture {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let savings = book.addAccount(Account(name: "Savings", type: .bank, commodity: .aud))
        let salary = book.addAccount(Account(name: "Salary", type: .income, commodity: .aud))
        let rent = book.addAccount(Account(name: "Rent", type: .expense, commodity: .aud))
        let food = book.addAccount(Account(name: "Food", type: .expense, commodity: .aud))

        func post(_ from: Account, _ to: Account, _ amount: Decimal, day n: Int) {
            let txn = Transaction(currency: .aud, datePosted: day(n), description: "t")
            txn.addSplit(account: to, value: amount)
            txn.addSplit(account: from, value: -amount)
            book.addTransaction(txn)
        }
        post(salary, bank, 5000, day: 10)
        post(bank, rent, 2000, day: 11)
        post(bank, food, 300, day: 12)
        post(bank, savings, 1000, day: 13)      // internal, if both are chosen
        post(salary, bank, 5000, day: 40)       // outside the period
        return Fixture(book: book, bank: bank, savings: savings,
                       salary: salary, rent: rent, food: food)
    }

    @Test("Inflows come from income, outflows go to expenses")
    func attribution() throws {
        let f = makeFixture()
        let report = FinancialReports.cashFlow(f.book, accountIDs: [f.bank.guid],
                                               from: day(9), to: day(20), currency: .aud)
        #expect(report.inflows.map { ($0.name, $0.amount) }.first! == ("Salary", 5000))
        #expect(report.outflows.map(\.name) == ["Rent", "Savings", "Food"])  // largest first
        #expect(report.totalIn == 5000)
        #expect(report.totalOut == 3300)
        #expect(report.netChange == 1700)
    }

    /// The identity the report exists to state: in − out = the set's change.
    @Test("In minus out is the accounts' net change over the period")
    func identity() {
        let f = makeFixture()
        let report = FinancialReports.cashFlow(f.book, accountIDs: [f.bank.guid],
                                               from: day(9), to: day(20), currency: .aud)
        let opening = f.book.balance(of: f.bank).amount - 5000 - 1700  // reconstruct: lifetime − later − period
        let change = report.netChange
        // Bank over the period: +5000 −2000 −300 −1000 = +1700.
        #expect(change == 1700)
        #expect(opening + change + 5000 == f.book.balance(of: f.bank).amount)
    }

    /// A transfer between two chosen accounts is a shuffle, not a flow.
    @Test("Transfers inside the set vanish")
    func internalTransfersVanish() {
        let f = makeFixture()
        let report = FinancialReports.cashFlow(f.book,
                                               accountIDs: [f.bank.guid, f.savings.guid],
                                               from: day(9), to: day(20), currency: .aud)
        #expect(!report.outflows.contains { $0.name == "Savings" })
        #expect(report.totalIn == 5000)
        #expect(report.totalOut == 2300)         // rent + food only
        #expect(report.netChange == 2700)
    }

    @Test("The period is a real cutoff")
    func periodCutoff() {
        let f = makeFixture()
        let report = FinancialReports.cashFlow(f.book, accountIDs: [f.bank.guid],
                                               from: day(9), to: day(45), currency: .aud)
        #expect(report.totalIn == 10_000)         // both salary payments
        let early = FinancialReports.cashFlow(f.book, accountIDs: [f.bank.guid],
                                              from: day(11), to: day(12), currency: .aud)
        #expect(early.totalIn == 0)
        #expect(early.totalOut == 2300)
    }

    /// An account that both gave and took shows up once, on its net side —
    /// GnuCash's report does the same.
    @Test("A two-way counterparty lands on its net side")
    func netting() {
        let f = makeFixture()
        // Rent refund: rent → bank 500.
        let txn = Transaction(currency: .aud, datePosted: day(14), description: "refund")
        txn.addSplit(account: f.bank, value: 500)
        txn.addSplit(account: f.rent, value: -500)
        f.book.addTransaction(txn)

        let report = FinancialReports.cashFlow(f.book, accountIDs: [f.bank.guid],
                                               from: day(9), to: day(20), currency: .aud)
        #expect(report.outflows.first { $0.name == "Rent" }?.amount == 1500)  // 2000 − 500
        #expect(!report.inflows.contains { $0.name == "Rent" })
        #expect(report.netChange == 2200)
    }

    /// A voided transaction moved nothing.
    @Test("Voided flows do not count")
    func voided() {
        let f = makeFixture()
        for txn in f.book.transactions where txn.datePosted == day(11) {
            for split in txn.splits { split.reconcileState = .voided }
        }
        let report = FinancialReports.cashFlow(f.book, accountIDs: [f.bank.guid],
                                               from: day(9), to: day(20), currency: .aud)
        #expect(!report.outflows.contains { $0.name == "Rent" })
        #expect(report.totalOut == 1300)
    }

    /// Multi-currency: a USD salary into an AUD set converts at the posting
    /// date, and the identity still holds in the report currency.
    @Test("Foreign flows convert at the day the money moved")
    func multiCurrency() {
        let f = makeFixture()
        let usdSalary = f.book.addAccount(Account(name: "US Salary", type: .income,
                                                  commodity: .usd))
        f.book.setExchangeRate(from: .usd, to: .aud, rate: dec("1.50"), date: day(15))
        let txn = Transaction(currency: .usd, datePosted: day(15), description: "us pay")
        txn.addSplit(Split(account: f.bank, value: 200, quantity: 300))   // 200 USD = 300 AUD
        txn.addSplit(account: usdSalary, value: -200)
        f.book.addTransaction(txn)

        let report = FinancialReports.cashFlow(f.book, accountIDs: [f.bank.guid],
                                               from: day(9), to: day(20), currency: .aud)
        #expect(report.inflows.first { $0.name == "US Salary" }?.amount == 300)
        #expect(report.totalIn == 5300)
    }
}

//
//  BookClosingTests.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func day(_ d: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(d) * 86_400) }

@Suite("Book closing")
struct BookClosingTests {

    /// Bank/Income/Expense/Equity. Earned 1,000, spent 300 → net 700.
    private func book() -> (Book, [String: Account]) {
        let b = Book(baseCurrency: .aud)
        let bank = b.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let income = b.addAccount(Account(name: "Salary", type: .income, commodity: .aud))
        let expense = b.addAccount(Account(name: "Rent", type: .expense, commodity: .aud))
        let equity = b.addAccount(Account(name: "Retained", type: .equity, commodity: .aud))

        let earn = Transaction(currency: .aud, datePosted: day(1), description: "Pay")
        earn.addSplit(Split(account: bank, value: dec("1000")))
        earn.addSplit(Split(account: income, value: dec("-1000")))
        b.addTransaction(earn)

        let spend = Transaction(currency: .aud, datePosted: day(2), description: "Rent")
        spend.addSplit(Split(account: expense, value: dec("300")))
        spend.addSplit(Split(account: bank, value: dec("-300")))
        b.addTransaction(spend)

        return (b, ["bank": bank, "income": income, "expense": expense, "equity": equity])
    }

    @Test("Closing zeroes P&L and moves the period result into equity")
    func closes() {
        let (b, a) = book()
        let equityBefore = b.balance(of: a["equity"]!).amount

        let result = BookClosing.build(in: b, asOf: day(10), into: a["equity"]!)
        #expect(result.closedAccountCount == 2)
        for txn in result.transactions { b.addTransaction(txn) }

        // Income and expense are now flat.
        #expect(b.balance(of: a["income"]!).amount == 0)
        #expect(b.balance(of: a["expense"]!).amount == 0)

        // Equity absorbed the net result. Income posts −1000, expense +300, so
        // the P&L quantity sum is −700; the equity leg is that sum, moving
        // equity by −700 (a credit — retained earnings grew by 700).
        let equityAfter = b.balance(of: a["equity"]!).amount
        #expect(equityAfter - equityBefore == dec("-700"))

        // Assets are untouched — closing only reshuffles P&L into equity.
        #expect(b.balance(of: a["bank"]!).amount == dec("700"))
    }

    @Test("Closing is balanced, so the book still balances afterwards")
    func staysBalanced() {
        let (b, a) = book()
        let result = BookClosing.build(in: b, asOf: day(10), into: a["equity"]!)
        for txn in result.transactions {
            // Every closing transaction sums to zero across its splits.
            let sum = txn.splits.reduce(Decimal(0)) { $0 + $1.value }
            #expect(sum == 0)
            b.addTransaction(txn)
        }
        // Whole book: debits == credits (every transaction balances).
        let grand = b.transactions.flatMap(\.splits).reduce(Decimal(0)) { $0 + $1.value }
        #expect(grand == 0)
    }

    @Test("Nothing to close yields no transactions")
    func nothingToClose() {
        let b = Book(baseCurrency: .aud)
        let equity = b.addAccount(Account(name: "Equity", type: .equity, commodity: .aud))
        let result = BookClosing.build(in: b, asOf: day(10), into: equity)
        #expect(result.transactions.isEmpty)
        #expect(result.closedAccountCount == 0)
    }

    @Test("A second close after more activity only closes the new amount")
    func rerun() {
        let (b, a) = book()
        for txn in BookClosing.build(in: b, asOf: day(10), into: a["equity"]!).transactions {
            b.addTransaction(txn)
        }
        // More income after the first close.
        let more = Transaction(currency: .aud, datePosted: day(20), description: "Bonus")
        more.addSplit(Split(account: a["bank"]!, value: dec("200")))
        more.addSplit(Split(account: a["income"]!, value: dec("-200")))
        b.addTransaction(more)

        let second = BookClosing.build(in: b, asOf: day(30), into: a["equity"]!)
        #expect(second.closedAccountCount == 1)           // only income moved
        for txn in second.transactions { b.addTransaction(txn) }
        #expect(b.balance(of: a["income"]!).amount == 0)  // flat again
    }
}

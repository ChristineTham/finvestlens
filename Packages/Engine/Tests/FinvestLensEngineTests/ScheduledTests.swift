//
//  ScheduledTests.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
}
private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d))!
}

@Suite("Recurrence")
struct RecurrenceTests {

    @Test("Monthly occurrences step by month")
    func monthly() {
        let r = Recurrence(period: .monthly, interval: 1, startDate: date(2026, 1, 15))
        let dates = r.occurrences(since: nil, through: date(2026, 4, 15))
        #expect(dates == [date(2026, 1, 15), date(2026, 2, 15), date(2026, 3, 15), date(2026, 4, 15)])
    }

    @Test("Weekly with interval")
    func fortnightly() {
        let r = Recurrence(period: .weekly, interval: 2, startDate: date(2026, 1, 1))
        let dates = r.occurrences(since: nil, through: date(2026, 1, 31))
        #expect(dates == [date(2026, 1, 1), date(2026, 1, 15), date(2026, 1, 29)])
    }

    @Test("since excludes already-generated occurrences")
    func sinceExcludes() {
        let r = Recurrence(period: .monthly, startDate: date(2026, 1, 15))
        let dates = r.occurrences(since: date(2026, 2, 15), through: date(2026, 4, 15))
        #expect(dates == [date(2026, 3, 15), date(2026, 4, 15)])
    }

    @Test("next occurrence strictly after a date")
    func next() {
        let r = Recurrence(period: .monthly, startDate: date(2026, 1, 15))
        #expect(r.next(after: date(2026, 1, 15)) == date(2026, 2, 15))
        #expect(r.next(after: date(2026, 1, 10)) == date(2026, 1, 15))
    }
}

@Suite("Scheduled transaction")
struct ScheduledTransactionTests {

    private func makeBook() -> (Book, expense: GncGUID, bank: GncGUID) {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let rent = book.addAccount(Account(name: "Rent", type: .expense, commodity: .aud))
        return (book, rent.guid, bank.guid)
    }

    private func rentSX(_ expense: GncGUID, _ bank: GncGUID) -> ScheduledTransaction {
        ScheduledTransaction(
            name: "Rent", currency: .aud, description: "Monthly rent",
            recurrence: Recurrence(period: .monthly, startDate: date(2026, 1, 1)),
            splits: [
                ScheduledSplit(accountGUID: expense, value: Decimal(500)),
                ScheduledSplit(accountGUID: bank, value: Decimal(-500)),
            ]
        )
    }

    @Test("Template balances and lists due dates")
    func dueDates() {
        let (_, expense, bank) = makeBook()
        let sx = rentSX(expense, bank)
        #expect(sx.isBalanced)
        #expect(sx.dueDates(through: date(2026, 3, 1)).count == 3)   // Jan, Feb, Mar
    }

    @Test("Posting creates a balanced transaction in the book")
    func post() throws {
        let (book, expense, bank) = makeBook()
        let sx = rentSX(expense, bank)
        let txn = try #require(ScheduledTransactionService.post(sx, date: date(2026, 1, 1), into: book))
        #expect(txn.isBalanced)
        #expect(book.transactions.count == 1)
        let rentAccount = try #require(book.account(with: expense))
        #expect(book.balance(of: rentAccount).amount == Decimal(500))
    }

    @Test("Pending aggregates and sorts across schedules")
    func pending() {
        let (_, expense, bank) = makeBook()
        let sx = rentSX(expense, bank)
        let pending = ScheduledTransactionService.pending([sx], through: date(2026, 2, 15))
        #expect(pending.count == 2)
        #expect(pending.first?.date == date(2026, 1, 1))
    }
}

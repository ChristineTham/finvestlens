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

    @Test("Monthly on the 31st re-anchors instead of drifting (GnuCash parity)")
    func monthEndNoDrift() {
        let r = Recurrence(period: .monthly, startDate: date(2025, 1, 31))
        let dates = r.occurrences(since: nil, through: date(2025, 6, 30))
        #expect(dates == [date(2025, 1, 31), date(2025, 2, 28), date(2025, 3, 31),
                          date(2025, 4, 30), date(2025, 5, 31), date(2025, 6, 30)])
    }

    @Test("Yearly from Feb 29 restores the leap day (GnuCash parity)")
    func leapYearAnchor() {
        let r = Recurrence(period: .yearly, startDate: date(2020, 2, 29))
        let dates = r.occurrences(since: nil, through: date(2024, 3, 1))
        #expect(dates == [date(2020, 2, 29), date(2021, 2, 28), date(2022, 2, 28),
                          date(2023, 2, 28), date(2024, 2, 29)])
    }

    @Test("End-of-month snaps the start and tracks each month's last day")
    func endOfMonth() {
        let r = Recurrence(period: .endOfMonth, startDate: date(2025, 1, 30))
        #expect(r.startDate == date(2025, 1, 31))     // aligned to last day
        let dates = r.occurrences(since: nil, through: date(2025, 4, 30))
        #expect(dates == [date(2025, 1, 31), date(2025, 2, 28),
                          date(2025, 3, 31), date(2025, 4, 30)])
    }

    @Test("Nth-weekday keeps the 3rd Tuesday each month")
    func nthWeekday() {
        // 2025-01-21 is the 3rd Tuesday of January.
        let r = Recurrence(period: .nthWeekday, startDate: date(2025, 1, 21))
        let dates = r.occurrences(since: nil, through: date(2025, 4, 30))
        #expect(dates == [date(2025, 1, 21), date(2025, 2, 18),
                          date(2025, 3, 18), date(2025, 4, 15)])
    }

    @Test("Last-weekday keeps the last Friday each month")
    func lastWeekday() {
        // 2025-01-31 is the last Friday of January.
        let r = Recurrence(period: .lastWeekday, startDate: date(2025, 1, 31))
        let dates = r.occurrences(since: nil, through: date(2025, 4, 30))
        #expect(dates == [date(2025, 1, 31), date(2025, 2, 28),
                          date(2025, 3, 28), date(2025, 4, 25)])
    }

    @Test("Once fires exactly once")
    func once() {
        let r = Recurrence(period: .once, startDate: date(2026, 1, 15))
        #expect(r.occurrences(since: nil, through: date(2027, 1, 1)) == [date(2026, 1, 15)])
        #expect(r.next(after: date(2026, 1, 15)) == nil)
        #expect(r.next(after: date(2026, 1, 10)) == date(2026, 1, 15))
    }

    @Test("Weekend-adjust moves a weekend occurrence off the weekend")
    func weekendAdjust() {
        // The 15th of March 2025 is a Saturday.
        let back = Recurrence(period: .monthly, startDate: date(2025, 3, 15), weekendAdjust: .back)
        #expect(back.next(after: date(2025, 2, 20)) == date(2025, 3, 14))   // → Friday
        let fwd = Recurrence(period: .monthly, startDate: date(2025, 3, 15), weekendAdjust: .forward)
        #expect(fwd.next(after: date(2025, 2, 20)) == date(2025, 3, 17))    // → Monday
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

    @Test("Scheduled-split formulas resolve variables at instantiation (FR-SCH-02)")
    func splitFormulas() {
        let (book, expense, bank) = makeBook()
        // A loan payment split by formula: principal + interest to the bank,
        // matched by the expense legs — variables supplied at post time.
        let sx = ScheduledTransaction(
            name: "Loan payment", currency: .aud,
            recurrence: Recurrence(period: .monthly, startDate: date(2026, 1, 1)),
            splits: [
                ScheduledSplit(accountGUID: expense, value: 0, formula: "principal + interest"),
                ScheduledSplit(accountGUID: bank, value: 0, formula: "-(principal + interest)"),
            ])

        #expect(sx.variableNames == ["interest", "principal"])

        let vars = ["principal": Decimal(800), "interest": Decimal(200)]
        let txn = try! #require(ScheduledTransactionService.post(
            sx, date: date(2026, 1, 1), into: book, variables: vars))
        let toExpense = txn.splits.first { $0.account?.guid == expense }
        #expect(toExpense?.value == Decimal(1000))
        #expect(txn.isBalanced)
    }

    @Test("Advance-create days create instances ahead of their due date")
    func advanceCreate() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let sx = ScheduledTransaction(
            name: "Rent", currency: .aud,
            recurrence: Recurrence(period: .monthly, startDate: date(2026, 1, 15)),
            splits: [ScheduledSplit(accountGUID: .random(), value: 0)],
            advanceCreateDays: 5)
        // Asking through Feb 12 — three days before the Feb 15 occurrence. The
        // 5-day advance window pulls Feb 15 in; without it only Jan 15 shows.
        let due = sx.dueDates(through: date(2026, 2, 12), calendar: cal)
        #expect(due == [date(2026, 1, 15), date(2026, 2, 15)])

        var noAdvance = sx; noAdvance.advanceCreateDays = 0
        #expect(noAdvance.dueDates(through: date(2026, 2, 12), calendar: cal) == [date(2026, 1, 15)])
    }

    @Test("Advance-remind lists upcoming instances without creating them")
    func advanceRemind() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let sx = ScheduledTransaction(
            name: "Rent", currency: .aud,
            recurrence: Recurrence(period: .monthly, startDate: date(2026, 1, 15)),
            splits: [ScheduledSplit(accountGUID: .random(), value: 0)],
            advanceRemindDays: 10)
        // Through Feb 10, remind window reaches Feb 20 → the Feb 15 occurrence.
        #expect(sx.remindDates(through: date(2026, 2, 10), calendar: cal) == [date(2026, 2, 15)])
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

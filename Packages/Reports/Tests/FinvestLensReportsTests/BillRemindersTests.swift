//
//  BillRemindersTests.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensReports

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
private func day(_ y: Int, _ m: Int, _ d: Int) -> Date { utc.date(from: DateComponents(year: y, month: m, day: d))! }

@Suite("Bill reminders")
struct BillRemindersTests {

    private func fixture() -> (Book, ScheduledTransaction) {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let rent = book.addAccount(Account(name: "Rent", type: .expense, commodity: .aud))
        let sx = ScheduledTransaction(
            name: "Rent", currency: .aud,
            recurrence: Recurrence(period: .monthly, startDate: day(2026, 1, 1)),
            splits: [
                ScheduledSplit(accountGUID: rent.guid, value: dec("800")),
                ScheduledSplit(accountGUID: bank.guid, value: dec("-800")),
            ])
        return (book, sx)
    }

    @Test("Classifies overdue, due-soon and upcoming; amount is the outflow")
    func statuses() {
        let (book, sx) = fixture()
        // asOf = Feb 5. Jan 1 (overdue), Feb 1 (overdue), Mar 1 (upcoming).
        let bills = FinancialReports.billReminders(
            book, scheduled: [sx],
            from: day(2026, 1, 1), to: day(2026, 3, 31), asOf: day(2026, 2, 5))
        #expect(bills.allSatisfy { $0.amount == dec("800") })
        #expect(bills.first { $0.dueDate == day(2026, 1, 1) }?.status == .overdue)
        #expect(bills.first { $0.dueDate == day(2026, 3, 1) }?.status == .upcoming)
    }

    @Test("A matching posted transaction marks the bill paid")
    func paid() {
        let (book, sx) = fixture()
        let paid = Transaction(currency: .aud, datePosted: day(2026, 2, 1), description: "Rent")
        paid.addSplit(account: book.accounts.first { $0.name == "Rent" }!, value: dec("800"))
        paid.addSplit(account: book.accounts.first { $0.name == "Bank" }!, value: dec("-800"))
        book.addTransaction(paid)

        let bills = FinancialReports.billReminders(
            book, scheduled: [sx],
            from: day(2026, 2, 1), to: day(2026, 2, 28), asOf: day(2026, 2, 15))
        #expect(bills.first { $0.dueDate == day(2026, 2, 1) }?.status == .paid)
    }
}

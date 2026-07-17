//
//  AverageBalanceTests.swift
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

@Suite("Average balance")
struct AverageBalanceTests {

    /// A UTC calendar keeps day boundaries deterministic across machines.
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")!
        return f.date(from: "\(iso)T00:00:00Z")!
    }

    private func book() -> (Book, Account) {
        let book = Book(baseCurrency: .aud)
        let bank = Account(name: "Bank", type: .bank, commodity: .aud)
        book.addAccount(bank)
        func post(_ iso: String, _ amount: String) {
            let txn = Transaction(currency: .aud, datePosted: date(iso), description: iso)
            txn.addSplit(account: bank, value: dec(amount), quantity: dec(amount))
            txn.addSplit(account: book.rootAccount, value: dec("-\(amount)"))
            book.addTransaction(txn)
        }
        // Mirrors the reference book's October Torrens shape: +100 on the 3rd,
        // +100 on the 17th, so daily balances are 0 (days 1–2), 100 (3–16),
        // 200 (17–31) → mean over 31 days.
        post("2025-10-03", "100")
        post("2025-10-17", "100")
        return (book, bank)
    }

    @Test("Monthly average is the mean of daily balances")
    func monthlyAverage() {
        let (book, _) = book()
        let report = FinancialReports.averageBalance(
            book, accounts: book.accounts.filter { $0.type == .bank },
            currency: .aud, from: date("2025-10-01"), to: date("2025-10-31"),
            step: .month, calendar: utc)

        #expect(report.intervals.count == 1)
        let october = report.intervals[0]
        // 0×2 + 100×14 + 200×15 = 4400 over 31 days.
        #expect(october.dayCount == 31)
        let expected = dec("4400") / dec("31")
        #expect(abs(october.average - expected) < dec("0.0000001"))
        #expect(october.maximum == dec("200"))
        #expect(october.minimum == dec("0"))
        #expect(october.gain == dec("200"))
        #expect(october.loss == dec("0"))
        #expect(october.profit == dec("200"))
    }

    @Test("A balance carried in from before the range seeds it without a flow")
    func priorBalance() {
        let (book, _) = book()   // +200 total, all before November
        let report = FinancialReports.averageBalance(
            book, accounts: book.accounts.filter { $0.type == .bank },
            currency: .aud, from: date("2025-11-01"), to: date("2025-11-30"),
            step: .month, calendar: utc)

        let november = report.intervals[0]
        // Flat at 200 the whole month; no postings, so no gain/loss.
        #expect(november.average == dec("200"))
        #expect(november.maximum == dec("200"))
        #expect(november.minimum == dec("200"))
        #expect(november.gain == dec("0"))
        #expect(november.loss == dec("0"))
        #expect(november.profit == dec("0"))
    }

    @Test("Weekly step splits the range into seven-day intervals")
    func weeklyStep() {
        let (book, _) = book()
        let report = FinancialReports.averageBalance(
            book, accounts: book.accounts.filter { $0.type == .bank },
            currency: .aud, from: date("2025-10-01"), to: date("2025-10-28"),
            step: .week, calendar: utc)

        // Four whole weeks: Oct 1–7, 8–14, 15–21, 22–28.
        #expect(report.intervals.count == 4)
        #expect(report.intervals.allSatisfy { $0.dayCount == 7 })
        // Week 1 (Oct 1–7): 0 on 1–2, 100 on 3–7 → 500/7.
        #expect(abs(report.intervals[0].average - dec("500") / dec("7")) < dec("0.0000001"))
        // Week 4 (Oct 22–28): flat at 200.
        #expect(report.intervals[3].average == dec("200"))
    }

    @Test("An outflow registers as loss and lowers the minimum")
    func outflow() {
        let book = Book(baseCurrency: .aud)
        let bank = Account(name: "Bank", type: .bank, commodity: .aud)
        book.addAccount(bank)
        func post(_ iso: String, _ amount: String) {
            let txn = Transaction(currency: .aud, datePosted: date(iso), description: iso)
            txn.addSplit(account: bank, value: dec(amount), quantity: dec(amount))
            txn.addSplit(account: book.rootAccount, value: dec("-\(amount)"))
            book.addTransaction(txn)
        }
        post("2025-10-05", "300")
        post("2025-10-20", "-100")

        let report = FinancialReports.averageBalance(
            book, accounts: [bank], currency: .aud,
            from: date("2025-10-01"), to: date("2025-10-31"), step: .month, calendar: utc)
        let october = report.intervals[0]
        #expect(october.maximum == dec("300"))
        #expect(october.minimum == dec("0"))
        #expect(october.gain == dec("300"))
        #expect(october.loss == dec("100"))
        #expect(october.profit == dec("200"))
    }
}

//
//  TransactionReportTests.swift
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
private func day(_ d: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(d) * 86_400) }

@Suite("Transaction report")
struct TransactionReportTests {

    private func book() -> (Book, Account) {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let income = book.addAccount(Account(name: "Salary", type: .income, commodity: .aud))
        let food = book.addAccount(Account(name: "Food", type: .expense, commodity: .aud))
        func tx(_ d: Int, _ desc: String, _ to: Account, _ amount: Decimal) {
            let t = Transaction(currency: .aud, datePosted: day(d), description: desc)
            t.addSplit(account: bank, value: amount)
            t.addSplit(account: to, value: -amount)
            book.addTransaction(t)
        }
        tx(0, "Opening pay", income, dec("1000"))     // before period
        tx(10, "Groceries", food, dec("-50"))
        tx(20, "Pay", income, dec("500"))
        return (book, bank)
    }

    @Test("Running balance seeded by opening, postings in period, totals")
    func report() {
        let (book, bank) = book()
        let report = FinancialReports.transactionReport(book, accountID: bank.guid,
                                                        from: day(5), to: day(30))!
        #expect(report.opening == dec("1000"))
        #expect(report.rows.count == 2)
        #expect(report.rows[0].balance == dec("950"))    // 1000 − 50
        #expect(report.rows[0].transfer == "Food")
        #expect(report.rows[1].balance == dec("1450"))   // 950 + 500
        #expect(report.total == dec("450"))
        #expect(report.closing == dec("1450"))
    }
}

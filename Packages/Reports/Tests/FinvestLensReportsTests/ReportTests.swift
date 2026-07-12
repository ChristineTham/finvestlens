//
//  ReportTests.swift
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
private let d1 = Date(timeIntervalSince1970: 1_600_000_000)
private let d2 = Date(timeIntervalSince1970: 1_610_000_000)
private let asOf = Date(timeIntervalSince1970: 1_700_000_000)

/// Bank/Salary/Groceries/CreditCard/Dining with:
///  d1: salary 1000 into Bank
///  d2: 200 groceries from Bank; 50 dining on the credit card
private func makeBook() -> Book {
    let book = Book(baseCurrency: .aud)
    let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
    let salary = book.addAccount(Account(name: "Salary", type: .income, commodity: .aud))
    let groceries = book.addAccount(Account(name: "Groceries", type: .expense, commodity: .aud))
    let card = book.addAccount(Account(name: "Visa", type: .credit, commodity: .aud))
    let dining = book.addAccount(Account(name: "Dining", type: .expense, commodity: .aud))

    let pay = Transaction(currency: .aud, datePosted: d1, description: "Salary")
    pay.addSplit(account: bank, value: dec("1000"))
    pay.addSplit(account: salary, value: dec("-1000"))
    book.addTransaction(pay)

    let shop = Transaction(currency: .aud, datePosted: d2, description: "Groceries")
    shop.addSplit(account: groceries, value: dec("200"))
    shop.addSplit(account: bank, value: dec("-200"))
    book.addTransaction(shop)

    let meal = Transaction(currency: .aud, datePosted: d2, description: "Dinner")
    meal.addSplit(account: dining, value: dec("50"))
    meal.addSplit(account: card, value: dec("-50"))
    book.addTransaction(meal)

    return book
}

@Suite("Financial reports")
struct ReportTests {

    @Test("Balance sheet balances and sign-adjusts liabilities")
    func balanceSheet() {
        let sheet = FinancialReports.balanceSheet(makeBook(), asOf: asOf, currency: .aud)

        #expect(sheet.totalAssets == dec("800"))          // Bank 1000 − 200
        #expect(sheet.totalLiabilities == dec("50"))       // Visa owed, shown positive
        #expect(sheet.retainedEarnings == dec("750"))      // income 1000 − expenses 250
        #expect(sheet.totalEquity == dec("750"))
        #expect(sheet.isBalanced)                          // 800 == 50 + 750

        #expect(sheet.assets.first { $0.name == "Bank" }?.amount == dec("800"))
        #expect(sheet.liabilities.first { $0.name == "Visa" }?.amount == dec("50"))
    }

    @Test("Income statement over the full period")
    func incomeStatement() {
        let statement = FinancialReports.incomeStatement(makeBook(), from: d1, to: asOf, currency: .aud)
        #expect(statement.totalIncome == dec("1000"))
        #expect(statement.totalExpenses == dec("250"))     // groceries 200 + dining 50
        #expect(statement.netIncome == dec("750"))
        #expect(statement.income.first?.name == "Salary")
    }

    @Test("Income statement respects the date window")
    func incomeStatementWindow() {
        // From d2 onward: salary (d1) is excluded; only the d2 expenses remain.
        let statement = FinancialReports.incomeStatement(makeBook(), from: d2, to: asOf, currency: .aud)
        #expect(statement.totalIncome == dec("0"))
        #expect(statement.totalExpenses == dec("250"))
        #expect(statement.netIncome == dec("-250"))
    }

    @Test("Net worth series tracks over time")
    func netWorth() {
        let points = FinancialReports.netWorthSeries(makeBook(), dates: [d1, asOf], currency: .aud)
        #expect(points.count == 2)
        #expect(points[0].netWorth == dec("1000"))         // after salary only
        #expect(points[1].assets == dec("800"))
        #expect(points[1].liabilities == dec("50"))
        #expect(points[1].netWorth == dec("750"))
    }

    @Test("Placeholder accounts are excluded")
    func placeholdersExcluded() {
        let book = makeBook()
        let placeholder = book.addAccount(Account(name: "Parent", type: .asset,
                                                  commodity: .aud, isPlaceholder: true))
        _ = placeholder
        let sheet = FinancialReports.balanceSheet(book, asOf: asOf, currency: .aud)
        #expect(sheet.assets.first { $0.name == "Parent" } == nil)
        #expect(sheet.isBalanced)
    }
}

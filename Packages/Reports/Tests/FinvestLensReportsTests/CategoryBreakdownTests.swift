//
//  CategoryBreakdownTests.swift
//  FinvestLens — Reports
//
//  The pie and the bars are bound to the income statement: slices sum to its
//  totals, months sum to the slices. Three views of a period that cannot tell
//  three stories — that binding is what these tests pin.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensReports

@Suite("Category breakdown")
struct CategoryBreakdownTests {

    /// A UTC calendar, so "which month is this posting in" does not depend on
    /// where the test machine happens to be.
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(n) * 86_400) }

    /// Two months of living: salary in, groceries under a Food parent, rent
    /// flat — so there is a subtree to roll and months to cut.
    private func makeBook() -> Book {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let salary = book.addAccount(Account(name: "Salary", type: .income, commodity: .aud))
        let food = Account(name: "Food", type: .expense, commodity: .aud)
        food.isPlaceholder = true
        _ = book.addAccount(food)
        let groceries = book.addAccount(Account(name: "Groceries", type: .expense,
                                                commodity: .aud), under: food)
        let dining = book.addAccount(Account(name: "Dining", type: .expense,
                                             commodity: .aud), under: food)
        let rent = book.addAccount(Account(name: "Rent", type: .expense, commodity: .aud))

        func post(_ from: Account, _ to: Account, _ amount: Decimal, day n: Int) {
            let txn = Transaction(currency: .aud, datePosted: day(n), description: "t")
            txn.addSplit(account: to, value: amount)
            txn.addSplit(account: from, value: -amount)
            book.addTransaction(txn)
        }
        // January 1970 (days 0–30) and February (31–58).
        post(salary, bank, 5000, day: 5)
        post(bank, groceries, 400, day: 6)
        post(bank, dining, 100, day: 7)
        post(bank, rent, 2000, day: 8)
        post(salary, bank, 5000, day: 36)
        post(bank, groceries, 450, day: 37)
        post(bank, rent, 2000, day: 38)
        return book
    }

    /// The binding: slices sum to the income statement's totals.
    @Test("Slices sum to the income statement")
    func slicesMatchStatement() {
        let book = makeBook()
        let breakdown = FinancialReports.categoryBreakdown(book, from: day(0), to: day(60),
                                                           currency: .aud, calendar: utc)
        let statement = FinancialReports.incomeStatement(book, from: day(0), to: day(60),
                                                         currency: .aud)
        #expect(breakdown.totalExpenses == statement.totalExpenses)
        #expect(breakdown.totalIncome == statement.totalIncome)
        #expect(breakdown.expenseSlices.reduce(Decimal(0)) { $0 + $1.amount }
                == breakdown.totalExpenses)
        #expect(breakdown.incomeSlices.reduce(Decimal(0)) { $0 + $1.amount }
                == breakdown.totalIncome)
    }

    /// One slice per *top-level* category: the Food subtree is one slice, not a
    /// slice per grocery run.
    @Test("A subtree is one slice, rolled")
    func subtreesRoll() throws {
        let book = makeBook()
        let breakdown = FinancialReports.categoryBreakdown(book, from: day(0), to: day(60),
                                                           currency: .aud, calendar: utc)
        #expect(breakdown.expenseSlices.map(\.name) == ["Rent", "Food"])   // largest first
        #expect(try #require(breakdown.expenseSlices.first { $0.name == "Food" }).amount == 950)
        #expect(try #require(breakdown.expenseSlices.first { $0.name == "Rent" }).amount == 4000)
    }

    /// …and the months sum to the slices.
    @Test("Months sum to the period")
    func monthsSumToPeriod() {
        let book = makeBook()
        let breakdown = FinancialReports.categoryBreakdown(book, from: day(0), to: day(60),
                                                           currency: .aud, calendar: utc)
        #expect(breakdown.months.count == 2)
        #expect(breakdown.months.reduce(Decimal(0)) { $0 + $1.income } == breakdown.totalIncome)
        #expect(breakdown.months.reduce(Decimal(0)) { $0 + $1.expenses }
                == breakdown.totalExpenses)
    }

    @Test("Each month carries its own money")
    func monthCut() throws {
        let book = makeBook()
        let breakdown = FinancialReports.categoryBreakdown(book, from: day(0), to: day(60),
                                                           currency: .aud, calendar: utc)
        let january = try #require(breakdown.months.first)
        let february = try #require(breakdown.months.last)
        #expect(january.income == 5000)
        #expect(january.expenses == 2500)     // 400 + 100 + 2000
        #expect(february.income == 5000)
        #expect(february.expenses == 2450)    // 450 + 2000
    }

    @Test("The period bounds are real")
    func periodBounds() {
        let book = makeBook()
        let januaryOnly = FinancialReports.categoryBreakdown(book, from: day(0), to: day(30),
                                                             currency: .aud, calendar: utc)
        #expect(januaryOnly.totalExpenses == 2500)
        #expect(januaryOnly.months.count == 1)
    }

    @Test("A category quiet in the period is not a slice")
    func quietCategoriesVanish() {
        let book = makeBook()
        _ = book.addAccount(Account(name: "Holidays", type: .expense, commodity: .aud))
        let breakdown = FinancialReports.categoryBreakdown(book, from: day(0), to: day(60),
                                                           currency: .aud, calendar: utc)
        #expect(!breakdown.expenseSlices.contains { $0.name == "Holidays" })
    }
}

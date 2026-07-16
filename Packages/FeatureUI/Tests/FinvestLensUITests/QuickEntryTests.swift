//
//  QuickEntryTests.swift
//  FinvestLens — FeatureUI
//
//  GnuCash's blank transaction row, as an entry bar at the foot of the
//  register. What the blank row is *for* is rapid two-split entry, and a
//  signed amount in the register's own convention — positive into this
//  account — covers it; a multi-split entry is ⌘T's job.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Quick entry")
struct QuickEntryTests {

    private struct Fixture {
        let model: AppModel
        let url: URL
        let bank: GncGUID
        let food: GncGUID
        let salary: GncGUID
    }

    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(n) * 86_400) }

    private func makeFixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        let salary = try #require(model.addAccount(name: "Salary", type: .income))
        return Fixture(model: model, url: url, bank: bank, food: food, salary: salary)
    }

    /// The register's sign convention: positive lands in this account.
    @Test("A positive amount is money into the register's account")
    func positiveIsIn() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let id = try #require(f.model.quickEnter(into: f.bank, transferFrom: f.salary,
                                                 amount: 100, date: day(0), description: "Pay"))
        let book = try #require(f.model.book)
        let txn = try #require(book.transaction(with: id))
        #expect(txn.isBalanced)
        #expect(txn.splits.first { $0.account?.guid == f.bank }?.value == 100)
        #expect(txn.splits.first { $0.account?.guid == f.salary }?.value == -100)
    }

    @Test("A negative amount is money out")
    func negativeIsOut() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let id = try #require(f.model.quickEnter(into: f.bank, transferFrom: f.food,
                                                 amount: -42, date: day(1),
                                                 description: "Groceries"))
        let book = try #require(f.model.book)
        let txn = try #require(book.transaction(with: id))
        #expect(txn.splits.first { $0.account?.guid == f.bank }?.value == -42)
        #expect(txn.splits.first { $0.account?.guid == f.food }?.value == 42)
        let bank = try #require(book.account(with: f.bank))
        #expect(book.balance(of: bank).amount == Decimal(-42))
    }

    /// Entering a transaction should end with it on screen.
    @Test("The register lands on the new row")
    func landsOnTheNewRow() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.selectedAccountID = f.bank
        let id = try #require(f.model.quickEnter(into: f.bank, transferFrom: f.salary,
                                                 amount: 10, date: day(0), description: "Pay"))
        let book = try #require(f.model.book)
        let expected = book.transaction(with: id)?.splits
            .first { $0.account?.guid == f.bank }?.guid
        #expect(f.model.pendingRegisterSplitID == expected)
        #expect(f.model.pendingRegisterSplitID != nil)
    }

    @Test("Zero amounts and self-transfers are refused")
    func refusesNonsense() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        #expect(f.model.quickEnter(into: f.bank, transferFrom: f.salary, amount: 0,
                                   date: day(0), description: "x") == nil)
        #expect(f.model.quickEnter(into: f.bank, transferFrom: f.bank, amount: 10,
                                   date: day(0), description: "x") == nil)
        #expect(f.model.book?.transactions.isEmpty == true)
    }

    // MARK: QuickFill

    /// Picking a known description fills the other side and the amount from the
    /// last transaction that used it.
    @Test("QuickFill offers the last transaction's shape")
    func quickFillFills() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        _ = f.model.quickEnter(into: f.bank, transferFrom: f.food, amount: -55,
                               date: day(0), description: "Groceries")

        let fill = try #require(f.model.quickFill(forDescription: "Groceries", into: f.bank))
        #expect(fill.transferID == f.food)
        #expect(fill.amount == -55)
    }

    /// A template the bar cannot hold fills nothing rather than half of
    /// something.
    @Test("A multi-split template fills nothing")
    func multiSplitTemplateDeclines() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        _ = try f.model.addTransaction(
            date: day(0), description: "Shop", currency: .aud,
            splits: [SplitInput(accountID: f.bank, value: -60),
                     SplitInput(accountID: f.food, value: 30),
                     SplitInput(accountID: f.salary, value: 30)])
        #expect(f.model.quickFill(forDescription: "Shop", into: f.bank) == nil)
    }

    /// A template that does not involve this account has no side to fill from.
    @Test("A template from another register fills nothing here")
    func foreignTemplateDeclines() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        _ = f.model.quickEnter(into: f.food, transferFrom: f.salary, amount: 10,
                               date: day(0), description: "Odd")
        #expect(f.model.quickFill(forDescription: "Odd", into: f.bank) == nil)
    }
}

//
//  BalancesByAccountTests.swift
//  FinvestLens — Engine
//
//  The one-walk balance map. It existed unwindowed (rebuildAccountTree uses
//  it) and untested; now that six reports stand on it, its semantics get
//  pinned: inclusive date bounds, voided excluded, and agreement with the
//  per-account `balance` — the slow oracle it exists to replace.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

@Suite("Balances by account")
struct BalancesByAccountTests {

    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(n) * 86_400) }

    private func makeBook() -> (Book, bank: Account, food: Account) {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let food = book.addAccount(Account(name: "Food", type: .expense, commodity: .aud))
        let salary = book.addAccount(Account(name: "Salary", type: .income, commodity: .aud))

        func post(_ from: Account, _ to: Account, _ amount: Decimal, day n: Int,
                  state: ReconcileState = .notReconciled) {
            let txn = Transaction(currency: .aud, datePosted: day(n), description: "t")
            let split = Split(account: to, value: amount)
            split.reconcileState = state
            txn.addSplit(split)
            txn.addSplit(account: from, value: -amount)
            book.addTransaction(txn)
        }
        post(salary, bank, 1000, day: 0)
        post(bank, food, 100, day: 5)
        post(bank, food, 200, day: 10)
        post(salary, bank, 999, day: 15, state: .voided)
        return (book, bank, food)
    }

    @Test("Unwindowed, the map is each account's lifetime balance")
    func lifetimeAgreesWithBalance() {
        let (book, bank, food) = makeBook()
        let map = book.balancesByAccount()
        #expect(map[ObjectIdentifier(bank)] == book.balance(of: bank).amount)
        #expect(map[ObjectIdentifier(food)] == book.balance(of: food).amount)
        #expect(map[ObjectIdentifier(bank)] == 700)     // 1000 − 100 − 200, void ignored
    }

    @Test("Bounds are inclusive at both ends")
    func inclusiveBounds() {
        let (book, bank, food) = makeBook()
        let window = book.balancesByAccount(from: day(5), to: day(10))
        #expect(window[ObjectIdentifier(food)] == 300)   // both postings
        #expect(window[ObjectIdentifier(bank)] == -300)
        let single = book.balancesByAccount(from: day(5), to: day(5))
        #expect(single[ObjectIdentifier(food)] == 100)   // day 5 only
    }

    @Test("A voided split never counts, windowed or not")
    func voidedExcluded() {
        let (book, bank, _) = makeBook()
        let map = book.balancesByAccount(from: day(15), to: day(15))
        #expect(map[ObjectIdentifier(bank)] == nil)      // the only day-15 posting is voided
    }

    @Test("The reconcile filter composes with the window")
    func filterComposes() {
        let (book, bank, food) = makeBook()
        for txn in book.transactions where txn.datePosted == day(5) {
            for split in txn.splits { split.reconcileState = .reconciled }
        }
        let map = book.balancesByAccount(filter: .reconciled, from: day(0), to: day(20))
        #expect(map[ObjectIdentifier(food)] == 100)
        #expect(map[ObjectIdentifier(bank)] == -100)
    }
}

//
//  ModelTests.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private let day = Date(timeIntervalSince1970: 1_700_000_000)

@Suite("Transaction balancing")
struct TransactionTests {

    @Test("A two-split transaction balances")
    func balancedTwoSplit() {
        let bank = Account(name: "Bank", type: .bank, commodity: .aud)
        let income = Account(name: "Salary", type: .income, commodity: .aud)
        let txn = Transaction(currency: .aud, datePosted: day, description: "Pay")
        txn.addSplit(account: bank, value: dec("100.00"))
        txn.addSplit(account: income, value: dec("-100.00"))

        #expect(txn.isBalanced)
        #expect(txn.imbalance.isZero)
        #expect(txn.splits.count == 2)
    }

    @Test("An unbalanced transaction is detected with its imbalance")
    func unbalanced() {
        let bank = Account(name: "Bank", type: .bank, commodity: .aud)
        let income = Account(name: "Salary", type: .income, commodity: .aud)
        let txn = Transaction(currency: .aud, datePosted: day)
        txn.addSplit(account: bank, value: dec("100.00"))
        txn.addSplit(account: income, value: dec("-90.00"))

        #expect(!txn.isBalanced)
        #expect(txn.imbalance.rounded.amount == dec("10.00"))
    }

    @Test("Residual below one minor unit still balances (Decimal tolerance)")
    func toleranceBalances() {
        let a = Account(name: "A", type: .bank, commodity: .aud)
        let b = Account(name: "B", type: .expense, commodity: .aud)
        let txn = Transaction(currency: .aud, datePosted: day)
        txn.addSplit(account: a, value: dec("100.000"))
        txn.addSplit(account: b, value: dec("-99.996"))

        #expect(txn.isBalanced) // imbalance 0.004 rounds to 0.00
    }

    @Test("Splits link back to their transaction")
    func backlink() {
        let a = Account(name: "A", type: .bank, commodity: .aud)
        let txn = Transaction(currency: .aud, datePosted: day)
        let split = txn.addSplit(account: a, value: dec("1.00"))
        #expect(split.transaction === txn)
        #expect(split.valueMoney?.commodity == .aud)
    }
}

@Suite("Book balances")
struct BookBalanceTests {

    private func makeBook() -> (Book, Account, Account) {
        let book = Book(baseCurrency: .aud)
        let assets = book.addAccount(Account(name: "Assets", type: .asset, commodity: .aud))
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud), under: assets)
        let income = book.addAccount(Account(name: "Salary", type: .income, commodity: .aud))
        return (book, bank, income)
    }

    @Test("Balances reflect posted splits")
    func balances() {
        let (book, bank, income) = makeBook()
        let txn = Transaction(currency: .aud, datePosted: day)
        txn.addSplit(account: bank, value: dec("100.00"))
        txn.addSplit(account: income, value: dec("-100.00"))
        book.addTransaction(txn)

        #expect(book.balance(of: bank).amount == dec("100.00"))
        #expect(book.balance(of: income).amount == dec("-100.00"))
    }

    @Test("Cleared/reconciled filters count the right splits")
    func reconcileFilters() {
        let (book, bank, income) = makeBook()
        let txn = Transaction(currency: .aud, datePosted: day)
        let bankSplit = txn.addSplit(account: bank, value: dec("100.00"))
        txn.addSplit(account: income, value: dec("-100.00"))
        book.addTransaction(txn)

        #expect(book.balance(of: bank, filter: .cleared).amount == dec("0"))
        bankSplit.reconcileState = .reconciled
        #expect(book.balance(of: bank, filter: .cleared).amount == dec("100.00"))
        #expect(book.balance(of: bank, filter: .reconciled).amount == dec("100.00"))
    }

    @Test("includingDescendants rolls up child balances")
    func rollUp() {
        let (book, bank, income) = makeBook()
        guard let assets = bank.parent else { Issue.record("no parent"); return }

        let txn = Transaction(currency: .aud, datePosted: day)
        txn.addSplit(account: bank, value: dec("100.00"))
        txn.addSplit(account: income, value: dec("-100.00"))
        book.addTransaction(txn)

        #expect(book.balance(of: assets).amount == dec("0"))           // no direct postings
        #expect(book.balance(of: assets, includingDescendants: true).amount == dec("100.00"))
    }

    @Test("Full account name is colon-delimited under the root")
    func fullName() {
        let (book, bank, _) = makeBook()
        #expect(bank.fullName == "Assets:Bank")
        withExtendedLifetime(book) {}  // Book owns the tree; keep it alive.
    }
}

@Suite("Scrub")
struct ScrubTests {

    @Test("Clean book reports no issues")
    func clean() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let income = book.addAccount(Account(name: "Salary", type: .income, commodity: .aud))
        let txn = Transaction(currency: .aud, datePosted: day)
        txn.addSplit(account: bank, value: dec("100.00"))
        txn.addSplit(account: income, value: dec("-100.00"))
        book.addTransaction(txn)

        #expect(Scrub.isClean(book))
    }

    @Test("Unbalanced transactions are found and repaired")
    func balanceRepair() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let income = book.addAccount(Account(name: "Salary", type: .income, commodity: .aud))
        let txn = Transaction(currency: .aud, datePosted: day)
        txn.addSplit(account: bank, value: dec("100.00"))
        txn.addSplit(account: income, value: dec("-90.00"))
        book.addTransaction(txn)

        let issues = Scrub.check(book)
        #expect(issues.contains { if case .unbalancedTransaction = $0 { return true } else { return false } })

        let adjusted = Scrub.balanceTransactions(in: book)
        #expect(adjusted.count == 1)
        #expect(txn.isBalanced)
        #expect(Scrub.isClean(book))

        let imbalance = Scrub.imbalanceAccount(for: .aud, in: book)
        #expect(book.balance(of: imbalance).amount == dec("-10.00"))
    }

    @Test("Orphan and degenerate transactions are reported")
    func structuralIssues() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let txn = Transaction(currency: .aud, datePosted: day)
        txn.addSplit(account: bank, value: dec("100.00"))
        txn.addSplit(Split(account: nil, value: dec("-100.00"))) // orphan
        book.addTransaction(txn)

        let issues = Scrub.check(book)
        #expect(issues.contains { if case .orphanSplit = $0 { return true } else { return false } })

        let single = Transaction(currency: .aud, datePosted: day)
        single.addSplit(account: bank, value: dec("5.00"))
        book.addTransaction(single)
        #expect(Scrub.check(book).contains { if case .degenerateTransaction = $0 { return true } else { return false } })
    }

    @Test("A zero-value single-split stub (GnuCash empty opening balance) is clean")
    func zeroValueStubIsClean() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let stub = Transaction(currency: .aud, datePosted: day, description: "Opening Balance")
        stub.addSplit(account: bank, value: 0)
        book.addTransaction(stub)
        #expect(Scrub.isClean(book))
    }
}

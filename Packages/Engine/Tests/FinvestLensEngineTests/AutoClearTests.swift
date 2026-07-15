//
//  AutoClearTests.swift
//  FinvestLens — Engine
//
//  A port of GnuCash's gnc-autoclear. The property that makes it worth having
//  is not "finds a subset that adds up" — it is "refuses when more than one
//  does". Clearing a guess about which transactions cleared the bank would be
//  wrong in a way that looks right.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

@Suite("Auto-clear")
struct AutoClearTests {

    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    /// A bank account with `amounts` posted to it, all not-reconciled.
    private func makeBook(_ amounts: [String],
                          states: [ReconcileState] = []) -> (Book, Account) {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let equity = book.addAccount(Account(name: "Opening", type: .equity, commodity: .aud))
        for (index, amount) in amounts.enumerated() {
            let txn = Transaction(currency: .aud,
                                  datePosted: Date(timeIntervalSince1970: TimeInterval(index) * 86_400),
                                  description: "t\(index)")
            let split = Split(account: bank, value: dec(amount))
            if index < states.count { split.reconcileState = states[index] }
            txn.addSplit(split)
            txn.addSplit(account: equity, value: -dec(amount))
            book.addTransaction(txn)
        }
        return (book, bank)
    }

    private func amounts(_ splits: [Split]) -> [Decimal] { splits.map(\.quantity).sorted() }

    @Test("Clears the one subset that reaches the statement balance")
    func findsUniqueSubset() throws {
        let (book, bank) = makeBook(["100", "20", "3"])
        // 100 + 3 = 103, and no other subset does.
        let found = try AutoClear.splitsToClear(in: bank, of: book, targetBalance: 103)
        #expect(amounts(found) == [3, 100])
    }

    @Test("Clears everything when the statement is the full balance")
    func clearsAll() throws {
        let (book, bank) = makeBook(["100", "20", "3"])
        let found = try AutoClear.splitsToClear(in: bank, of: book, targetBalance: 123)
        #expect(amounts(found) == [3, 20, 100])
    }

    /// The reason for the port. Two 50s: reaching 50 could mean either, and
    /// picking one would be a guess about someone's money.
    @Test("Refuses when more than one subset reaches the balance")
    func refusesAmbiguity() throws {
        let (book, bank) = makeBook(["50", "50", "7"])
        #expect(throws: AutoClear.Failure.ambiguous) {
            try AutoClear.splitsToClear(in: bank, of: book, targetBalance: 50)
        }
    }

    /// Ambiguity is not only about equal amounts: 30 + 20 and 50 are different
    /// sets reaching the same sum.
    @Test("Refuses when different amounts reach the same sum")
    func refusesAmbiguousSums() throws {
        let (book, bank) = makeBook(["50", "30", "20"])
        #expect(throws: AutoClear.Failure.ambiguous) {
            try AutoClear.splitsToClear(in: bank, of: book, targetBalance: 50)
        }
    }

    @Test("Says so when nothing adds up to the balance")
    func unreachable() throws {
        let (book, bank) = makeBook(["100", "20", "3"])
        #expect(throws: AutoClear.Failure.unreachable) {
            try AutoClear.splitsToClear(in: bank, of: book, targetBalance: 7)
        }
    }

    /// Already-cleared and reconciled splits count toward the balance rather
    /// than being something to choose — that is what makes the arithmetic agree
    /// with the reconcile window's Cleared figure.
    @Test("Cleared and reconciled splits come off the target, not the choices")
    func clearedSplitsReduceTheTarget() throws {
        let (book, bank) = makeBook(["100", "20", "3"],
                                    states: [.reconciled, .notReconciled, .notReconciled])
        // 100 is already reconciled, so reaching 120 means clearing just the 20.
        let found = try AutoClear.splitsToClear(in: bank, of: book, targetBalance: 120)
        #expect(amounts(found) == [20])
    }

    @Test("A statement matching what is already cleared has nothing to do")
    func alreadyAtTarget() throws {
        let (book, bank) = makeBook(["100", "20"], states: [.cleared, .notReconciled])
        #expect(throws: AutoClear.Failure.alreadyAtTarget) {
            try AutoClear.splitsToClear(in: bank, of: book, targetBalance: 100)
        }
    }

    @Test("Nothing uncleared is nothing to work with")
    func nothingUncleared() throws {
        let (book, bank) = makeBook(["100", "20"], states: [.reconciled, .reconciled])
        #expect(throws: AutoClear.Failure.nothingUncleared) {
            try AutoClear.splitsToClear(in: bank, of: book, targetBalance: 500)
        }
    }

    /// Negative amounts are the normal case for a bank account, and a target can
    /// sit below the cleared balance.
    @Test("Withdrawals clear as readily as deposits")
    func negativeAmounts() throws {
        let (book, bank) = makeBook(["500", "-40", "-7"], states: [.reconciled, .notReconciled,
                                                                   .notReconciled])
        let found = try AutoClear.splitsToClear(in: bank, of: book, targetBalance: 460)
        #expect(amounts(found) == [-40])
    }

    /// Money is decimal, and decimal sums are exact — the solver hashes minor
    /// units so 0.1 + 0.2 is 30 cents and not a floating-point apology.
    @Test("Cents add up exactly")
    func centsAreExact() throws {
        let (book, bank) = makeBook(["0.10", "0.20", "5.55"])
        let found = try AutoClear.splitsToClear(in: bank, of: book, targetBalance: dec("0.30"))
        #expect(amounts(found) == [dec("0.10"), dec("0.20")])
    }

    @Test("A voided split is not a candidate and does not count")
    func voidedIgnored() throws {
        let (book, bank) = makeBook(["100", "999"], states: [.notReconciled, .voided])
        let found = try AutoClear.splitsToClear(in: bank, of: book, targetBalance: 100)
        #expect(amounts(found) == [100])
    }

    /// The guard has to report rather than run until the machine gives out.
    @Test("Too many uncleared splits is refused, not attempted")
    func tooManySplits() throws {
        let (book, bank) = makeBook((0..<(AutoClear.Limits.splits + 1)).map { "\($0 + 1)" })
        #expect(throws: AutoClear.Failure.tooComplex) {
            try AutoClear.splitsToClear(in: bank, of: book, targetBalance: 1)
        }
    }

    /// A found subset must actually add up — the property, stated plainly.
    @Test("Whatever it returns sums to the target")
    func foundSubsetSums() throws {
        let (book, bank) = makeBook(["12.34", "56.78", "9.01", "23.45"])
        let target = dec("12.34") + dec("9.01")
        let found = try AutoClear.splitsToClear(in: bank, of: book, targetBalance: target)
        #expect(found.reduce(Decimal(0)) { $0 + $1.quantity } == target)
    }
}

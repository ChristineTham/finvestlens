//
//  ReconcileReportTests.swift
//  FinvestLens — Reports
//
//  The reconcile report's whole claim is an identity: every posting is
//  reconciled, cleared or outstanding — exactly one of the three — so the three
//  totals must add back to the account's balance. A report whose parts do not
//  sum to the whole is worse than no report, so that is what these pin, along
//  with the one figure GnuCash has already agreed: the reconciled balance.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensReports

@Suite("Reconcile report")
struct ReconcileReportTests {

    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(n) * 86_400) }

    /// A bank account carrying one posting of every reconcile state, including
    /// the two that are easy to get wrong — voided and frozen.
    private func makeBook() -> (Book, Account) {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let equity = book.addAccount(Account(name: "Opening", type: .equity, commodity: .aud))

        func post(_ amount: Decimal, _ state: ReconcileState, day n: Int,
                  reconciled: Date? = nil) {
            let txn = Transaction(currency: .aud, datePosted: day(n), description: "t\(n)")
            let split = Split(account: bank, value: amount)
            split.reconcileState = state
            split.reconcileDate = reconciled
            txn.addSplit(split)
            txn.addSplit(account: equity, value: -amount)
            book.addTransaction(txn)
        }

        post(1000, .reconciled, day: 1, reconciled: day(30))
        post(-250, .reconciled, day: 2, reconciled: day(30))
        post(500, .cleared, day: 3)
        post(-40, .notReconciled, day: 4)
        post(-9, .frozen, day: 5)
        post(99_999, .voided, day: 6)
        return (book, bank)
    }

    private func report(_ book: Book, _ bank: Account, asOf: Date = Date(timeIntervalSince1970: 86_400 * 365)) throws -> ReconcileReport {
        try #require(FinancialReports.reconcileReport(book, accountID: bank.guid, asOf: asOf))
    }

    /// The identity the report exists to state.
    @Test("The three totals add back to the balance")
    func partsSumToWhole() throws {
        let (book, bank) = makeBook()
        let r = try report(book, bank)
        #expect(r.isConsistent)
        #expect(r.reconciledBalance + r.clearedTotal + r.outstandingTotal == r.endingBalance)
    }

    /// The report must agree with the balance every other part of the app shows
    /// — this is the figure GnuCash puts at $57,909.82 on the reference book.
    @Test("The reconciled balance is the book's reconciled balance")
    func agreesWithTheBook() throws {
        let (book, bank) = makeBook()
        let r = try report(book, bank)
        #expect(r.reconciledBalance == book.balance(of: bank, filter: .reconciled).amount)
        #expect(r.reconciledBalance == 741)   // 1000 − 250 − 9 (frozen folds in)
    }

    @Test("The ending balance is the account's balance")
    func endingIsTheBalance() throws {
        let (book, bank) = makeBook()
        let r = try report(book, bank)
        #expect(r.endingBalance == book.balance(of: bank).amount)
        // 1000 - 250 + 500 - 40 - 9, with the voided 99,999 nowhere.
        #expect(r.endingBalance == 1201)
    }

    @Test("Reconciled postings are split into funds in and funds out")
    func fundsInAndOut() throws {
        let (book, bank) = makeBook()
        let r = try report(book, bank)
        #expect(r.fundsIn.map(\.amount) == [1000])
        #expect(r.fundsOut.map(\.amount) == [-250, -9])   // frozen −9 folds in
        #expect(r.totalIn == 1000)
        #expect(r.totalOut == -259)
        #expect(r.totalIn + r.totalOut == r.reconciledBalance)
    }

    @Test("Cleared sits between reconciled and outstanding")
    func clearedBalance() throws {
        let (book, bank) = makeBook()
        let r = try report(book, bank)
        #expect(r.cleared.map(\.amount) == [500])
        #expect(r.clearedBalance == 1241)      // 741 reconciled + 500 cleared
        #expect(r.clearedBalance == book.balance(of: bank, filter: .cleared).amount)
    }

    /// Frozen (f) is a locked-reconciled state — GnuCash folds it into the
    /// reconciled balance, not outstanding. Only genuinely unreconciled (n)
    /// postings are outstanding.
    @Test("Frozen counts as reconciled, not outstanding")
    func frozenIsReconciled() throws {
        let (book, bank) = makeBook()
        let r = try report(book, bank)
        #expect(r.outstanding.map(\.amount) == [-40])
        #expect(r.outstandingTotal == -40)
        #expect(!r.cleared.contains { $0.state == .frozen })
        // The frozen −9 is a reconciled funds-out row.
        #expect(r.fundsOut.contains { $0.state == .frozen && $0.amount == -9 })
    }

    /// Voided postings are excluded from every balance in the book, and must be
    /// excluded here or the identity breaks by 99,999.
    @Test("A voided posting appears nowhere")
    func voidedExcluded() throws {
        let (book, bank) = makeBook()
        let r = try report(book, bank)
        let everyRow = r.fundsIn + r.fundsOut + r.cleared + r.outstanding
        #expect(!everyRow.contains { $0.amount == 99_999 })
        #expect(r.isConsistent)
    }

    /// Every posting has to land in exactly one group, or the totals stop
    /// accounting for the rows.
    @Test("Every posting lands in exactly one group")
    func noRowIsLostOrDoubled() throws {
        let (book, bank) = makeBook()
        let r = try report(book, bank)
        let ids = (r.fundsIn + r.fundsOut + r.cleared + r.outstanding).map(\.id)
        #expect(ids.count == Set(ids).count)          // none twice
        #expect(ids.count == 5)                       // all five that count
    }

    @Test("As-of excludes later postings, and the identity still holds")
    func asOfCutoff() throws {
        let (book, bank) = makeBook()
        let r = try report(book, bank, asOf: day(2))
        #expect(r.endingBalance == 750)
        #expect(r.cleared.isEmpty)
        #expect(r.outstanding.isEmpty)
        #expect(r.isConsistent)
    }

    @Test("Reconciled rows carry when they were reconciled")
    func reconcileDatesSurvive() throws {
        let (book, bank) = makeBook()
        let r = try report(book, bank)
        #expect(r.fundsIn.first?.reconcileDate == day(30))
        // An outstanding row has never been reconciled, so it has no date.
        #expect(r.outstanding.allSatisfy { $0.reconcileDate == nil })
    }

    @Test("An unknown account has no report")
    func unknownAccount() {
        let (book, _) = makeBook()
        #expect(FinancialReports.reconcileReport(book, accountID: .random(),
                                                 asOf: Date()) == nil)
    }

    @Test("An account with nothing in it reports zeroes, consistently")
    func emptyAccount() throws {
        let book = Book(baseCurrency: .aud)
        let empty = book.addAccount(Account(name: "Unused", type: .bank, commodity: .aud))
        let r = try report(book, empty)
        #expect(r.endingBalance == 0)
        #expect(r.isConsistent)
    }
}

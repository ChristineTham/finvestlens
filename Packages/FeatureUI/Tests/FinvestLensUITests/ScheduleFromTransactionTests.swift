//
//  ScheduleFromTransactionTests.swift
//  FinvestLens — FeatureUI
//
//  GnuCash's Transaction ▸ Schedule…. ScheduledView existed, the engine could
//  post occurrences, and there was no way to make a schedule out of a
//  transaction you had already entered — which is how most recurring
//  transactions are noticed: you pay the rent, and then think to schedule it.
//
//  The rule with a wrong answer is `lastPosted`. Seeded with the source's own
//  date, the schedule's first occurrence is the next one; left nil, the
//  schedule's first act is to post a duplicate of the transaction you copied.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Schedule from transaction")
struct ScheduleFromTransactionTests {

    private struct Fixture {
        let model: AppModel
        let url: URL
        let bank: GncGUID
        let rent: GncGUID
        let txn: GncGUID
    }

    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(n) * 86_400) }

    private func makeFixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let rent = try #require(model.addAccount(name: "Rent", type: .expense))
        let txn = try model.addTransaction(
            date: day(0), description: "Rent", currency: .aud,
            splits: [SplitInput(accountID: bank, value: -500, memo: "direct debit"),
                     SplitInput(accountID: rent, value: 500)])
        return Fixture(model: model, url: url, bank: bank, rent: rent, txn: txn)
    }

    @Test("A schedule copies the transaction that made it")
    func copiesTheSource() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        let id = try #require(f.model.scheduleTransaction(f.txn, period: .monthly))
        let scheduled = try #require(f.model.scheduledTransactions.first { $0.id == id })

        #expect(scheduled.name == "Rent")
        #expect(scheduled.transactionDescription == "Rent")
        #expect(scheduled.currency == .aud)
        #expect(scheduled.splits.map(\.value).sorted() == [-500, 500])
        #expect(scheduled.isBalanced)
        #expect(scheduled.isEnabled)
    }

    /// Per-split memos are part of what makes the next one the same as this one.
    @Test("Split memos come with it")
    func memosSurvive() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let id = try #require(f.model.scheduleTransaction(f.txn, period: .monthly))
        let scheduled = try #require(f.model.scheduledTransactions.first { $0.id == id })
        #expect(scheduled.splits.contains { $0.memo == "direct debit" })
    }

    /// The one that matters: scheduling the rent must not post the rent again.
    @Test("The transaction it was made from is not immediately due")
    func doesNotDuplicateTheSource() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let id = try #require(f.model.scheduleTransaction(f.txn, period: .monthly))
        let scheduled = try #require(f.model.scheduledTransactions.first { $0.id == id })

        #expect(scheduled.lastPosted == day(0))
        // Asked on the very day it was scheduled, nothing is owed.
        #expect(scheduled.dueDates(through: day(0)).isEmpty)
        #expect(f.model.pendingScheduled(through: day(0)).isEmpty)
    }

    @Test("The next occurrence is one period later")
    func nextOccurrence() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let id = try #require(f.model.scheduleTransaction(f.txn, period: .monthly))
        let scheduled = try #require(f.model.scheduledTransactions.first { $0.id == id })

        let due = scheduled.dueDates(through: day(40))
        #expect(due.count == 1)
        // A month after day 0, not day 0 again.
        #expect(try #require(due.first) > day(0))
    }

    /// And posting it produces one transaction, not two.
    @Test("Posting the schedule adds the next one only")
    func postingAddsOne() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.scheduleTransaction(f.txn, period: .monthly)

        let before = try #require(f.model.book).transactions.count
        let posted = f.model.postDueScheduled(through: day(40))
        #expect(posted == 1)
        #expect(try #require(f.model.book).transactions.count == before + 1)
        // The original is untouched and still there.
        #expect(f.model.book?.transaction(with: f.txn) != nil)
    }

    @Test("An interval of more than one is honoured")
    func interval() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let id = try #require(f.model.scheduleTransaction(f.txn, period: .weekly, interval: 2))
        let scheduled = try #require(f.model.scheduledTransactions.first { $0.id == id })
        #expect(scheduled.recurrence.interval == 2)
        #expect(scheduled.recurrence.period == .weekly)
        // Nothing in the first week; one in the third.
        #expect(scheduled.dueDates(through: day(7)).isEmpty)
        #expect(scheduled.dueDates(through: day(15)).count == 1)
    }

    @Test("A name given is a name kept")
    func customName() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let id = try #require(f.model.scheduleTransaction(f.txn, period: .monthly,
                                                          name: "Monthly rent"))
        #expect(f.model.scheduledTransactions.first { $0.id == id }?.name == "Monthly rent")
    }

    /// A schedule has to be called something in the list.
    @Test("A transaction with no description still gets a name")
    func namelessSource() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let blank = try f.model.addTransaction(
            date: day(1), description: "  ", currency: .aud,
            splits: [SplitInput(accountID: f.bank, value: -1),
                     SplitInput(accountID: f.rent, value: 1)])
        let id = try #require(f.model.scheduleTransaction(blank, period: .monthly))
        let scheduled = try #require(f.model.scheduledTransactions.first { $0.id == id })
        #expect(!scheduled.name.isEmpty)
    }

    @Test("An unknown transaction schedules nothing")
    func unknownTransaction() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        #expect(f.model.scheduleTransaction(.random(), period: .monthly) == nil)
        #expect(f.model.scheduledTransactions.isEmpty)
    }

    /// The template posts by account GUID, so a leg without an account would
    /// make a schedule that silently never fires.
    @Test("A leg with no account is refused rather than half-scheduled")
    func splitWithoutAccount() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let book = try #require(f.model.book)
        let txn = try #require(book.transaction(with: f.txn))
        txn.splits.first?.account = nil

        #expect(f.model.scheduleTransaction(f.txn, period: .monthly) == nil)
        #expect(f.model.scheduledTransactions.isEmpty)
    }
}

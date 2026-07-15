//
//  AutoClearSessionTests.swift
//  FinvestLens — FeatureUI
//
//  Auto-clear against a reconcile session. The solver is pinned in the Engine's
//  own tests; what these cover is the join — that it ticks the session's boxes
//  and nothing else, and that the resulting Cleared figure is the statement
//  balance, which is the whole claim being made.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Auto-clear session")
struct AutoClearSessionTests {

    private struct Fixture {
        let model: AppModel
        let url: URL
        let bank: GncGUID
    }

    private func makeFixture(_ amounts: [Decimal]) throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let income = try #require(model.addAccount(name: "Salary", type: .income))
        for (index, amount) in amounts.enumerated() {
            _ = try model.addTransaction(
                date: Date(timeIntervalSince1970: TimeInterval(index) * 86_400),
                description: "t\(index)", currency: .aud,
                splits: [SplitInput(accountID: bank, value: amount),
                         SplitInput(accountID: income, value: -amount)])
        }
        return Fixture(model: model, url: url, bank: bank)
    }

    private func begin(_ f: Fixture, statement: Decimal) {
        f.model.beginReconcile(accountID: f.bank,
                               statementDate: Date(timeIntervalSince1970: 86_400 * 365),
                               statementBalance: statement)
    }

    /// The claim auto-clear makes: after it, the Cleared figure *is* the
    /// statement balance and Finish is available.
    @Test("Auto-clear leaves the session balanced")
    func leavesSessionBalanced() throws {
        let f = try makeFixture([100, 20, 3])
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        begin(f, statement: 103)

        let result = f.model.autoClear()
        #expect(result == .success(2))

        let session = try #require(f.model.reconcileSession)
        #expect(session.clearedBalance == 103)
        #expect(session.difference == 0)
        #expect(session.isBalanced)
    }

    @Test("It ticks the chosen items and only those")
    func ticksTheRightItems() throws {
        let f = try makeFixture([100, 20, 3])
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        begin(f, statement: 103)
        f.model.autoClear()

        let session = try #require(f.model.reconcileSession)
        let ticked = session.items.filter(\.isCleared).map(\.amount).sorted()
        #expect(ticked == [3, 100])
        #expect(session.items.filter { !$0.isCleared }.map(\.amount) == [20])
    }

    /// An item ticked by hand that the solver did not choose was not part of the
    /// answer — leaving it on would make the total disagree with the statement
    /// it had just matched.
    @Test("Auto-clear replaces hand-ticked items rather than adding to them")
    func replacesExistingTicks() throws {
        let f = try makeFixture([100, 20, 3])
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        begin(f, statement: 103)

        let session = try #require(f.model.reconcileSession)
        let twenty = try #require(session.items.first { $0.amount == 20 })
        f.model.toggleReconcileItem(twenty.id)
        #expect(try #require(f.model.reconcileSession).clearedBalance == 20)

        f.model.autoClear()
        let after = try #require(f.model.reconcileSession)
        #expect(after.clearedBalance == 103)
        #expect(after.items.first { $0.amount == 20 }?.isCleared == false)
    }

    /// Nothing reaches the book until Finish — an auto-clear you disagree with
    /// costs a Cancel, not an undo.
    @Test("Auto-clear writes nothing to the book")
    func writesNothing() throws {
        let f = try makeFixture([100, 20, 3])
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        begin(f, statement: 103)
        f.model.autoClear()

        let book = try #require(f.model.book)
        let account = try #require(book.account(with: f.bank))
        #expect(book.splits(for: account).allSatisfy { $0.reconcileState == .notReconciled })

        f.model.cancelReconcile()
        #expect(book.splits(for: account).allSatisfy { $0.reconcileState == .notReconciled })
    }

    /// …and Finish is what makes it real.
    @Test("Finishing after an auto-clear reconciles exactly what it ticked")
    func finishAfterAutoClear() throws {
        let f = try makeFixture([100, 20, 3])
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        begin(f, statement: 103)
        f.model.autoClear()
        #expect(f.model.finishReconcile())

        let book = try #require(f.model.book)
        let account = try #require(book.account(with: f.bank))
        let reconciled = book.splits(for: account)
            .filter { $0.reconcileState == .reconciled }
            .map(\.quantity).sorted()
        #expect(reconciled == [3, 100])
        #expect(book.balance(of: account, filter: .reconciled).amount == 103)
    }

    @Test("An ambiguous statement is refused, in words")
    func ambiguousIsExplained() throws {
        let f = try makeFixture([50, 50, 7])
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        begin(f, statement: 50)

        #expect(f.model.autoClear() == .failure(.ambiguous))
        // And the session is left exactly as it was.
        let session = try #require(f.model.reconcileSession)
        #expect(session.items.allSatisfy { !$0.isCleared })
        #expect(f.model.describe(AutoClear.Failure.ambiguous).contains("More than one"))
    }

    @Test("An unreachable statement is refused, in words")
    func unreachableIsExplained() throws {
        let f = try makeFixture([100, 20, 3])
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        begin(f, statement: 7)
        #expect(f.model.autoClear() == .failure(.unreachable))
        #expect(!f.model.describe(AutoClear.Failure.unreachable).isEmpty)
    }

    @Test("Every failure has something to say")
    func everyFailureIsExplained() throws {
        let f = try makeFixture([1])
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let failures: [AutoClear.Failure] = [.alreadyAtTarget, .nothingUncleared, .unreachable,
                                             .ambiguous, .tooComplex]
        for failure in failures {
            #expect(f.model.describe(failure).count > 20)
        }
    }

    @Test("Auto-clear outside a session does nothing")
    func noSession() throws {
        let f = try makeFixture([100])
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        #expect(f.model.autoClear() == .failure(.nothingUncleared))
    }
}

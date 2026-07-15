//
//  LiveFindOracleTests.swift
//  FinvestLens — FeatureUI
//
//  Checks the Find engine against numbers **GnuCash itself computed**, on a
//  real book supplied via FL_PERF_FILE; skipped when unset, so CI stays
//  deterministic. Run as:
//
//      FL_PERF_FILE="/path/to/Book.finvestlens" \
//          FL_FIND_ACCOUNT="Assets:Joint:CDIA" \
//          FL_FIND_RECONCILED="57909.82" \
//          swift test --filter LiveFindOracleTests
//
//  GnuCash's register status bar reports, for the open account, the balance of
//  its reconciled splits. That figure is an independent oracle: find every
//  split in that account whose state is Reconciled, sum the values, and the
//  total must agree to the cent. It exercises the account and reconcile
//  criteria together — the exact pairing that must hold *per split*.
//
//  Works on a copy: the harness must never touch the live book.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

private let perfPath = ProcessInfo.processInfo.environment["FL_PERF_FILE"]
private let findAccount = ProcessInfo.processInfo.environment["FL_FIND_ACCOUNT"]
private let findReconciled = ProcessInfo.processInfo.environment["FL_FIND_RECONCILED"]

@MainActor
@Suite(.serialized)
struct LiveFindOracleTests {

    @Test("Reconciled splits in an account sum to GnuCash's reconciled balance")
    func reconciledBalanceMatchesGnuCash() async throws {
        guard let perfPath, let findAccount, let findReconciled,
              let expected = Decimal(string: findReconciled) else { return }

        let source = URL(fileURLWithPath: perfPath)
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("flfind-\(UUID().uuidString).finvestlens")
        try FileManager.default.copyItem(at: source, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }

        let model = AppModel()
        await model.openBook(at: copy, breakStaleLock: true)
        defer { model.close() }
        let book = try #require(model.book)

        let account = try #require(book.accounts.first { $0.fullName == findAccount },
                                   "no account named \(findAccount)")

        let query = FindQuery(criteria: [
            FindCriterion(test: .account(.isOneOf, [account.guid])),
            FindCriterion(test: .reconcile(.isOneOf, [.reconciled])),
        ])
        let splits = book.splitsMatching(query)
        let total = splits.reduce(Decimal(0)) { $0 + $1.quantity }

        print("find oracle: \(splits.count) reconciled splits in \(findAccount), total \(total)")
        #expect(total == expected,
                "GnuCash reports \(expected) reconciled in \(findAccount)")

        // Every hit really is in the account and really is reconciled — the
        // per-split rule, checked on 46k real transactions rather than a
        // three-line fixture.
        #expect(splits.allSatisfy { $0.account?.guid == account.guid })
        #expect(splits.allSatisfy { $0.reconcileState == .reconciled })
    }
}

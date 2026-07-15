//
//  LoadReporter.swift
//  FinvestLens — Persistence
//
//  Turns "I have built 12,000 of 46,553 transactions" into a fraction of the
//  whole load, using the measured per-row weights in ``BookLoadProgress``.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB

/// Sizes a load and emits throttled progress through it.
///
/// Only built when someone is watching: the row counts it needs cost ~0.19s, and
/// a read nobody can see should not pay for them.
struct LoadReporter {

    private let emit: @Sendable (BookLoadProgress) -> Void

    private let splitCount: Int
    private let txnCount: Int
    private let priceCount: Int

    /// Total weighted work, in the arbitrary units of ``LoadWeight``.
    private let totalWork: Double
    /// Work completed before the current stage starts.
    private var workBefore: Double = 0
    /// Last emitted percent, so we report ~100 times rather than ~250,000.
    private var lastPercent = -1

    init(db: Database, emit: @escaping @Sendable (BookLoadProgress) -> Void) throws {
        self.emit = emit
        splitCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM split") ?? 0
        txnCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM txn") ?? 0
        priceCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM price") ?? 0

        let work = Double(splitCount) * LoadWeight.perSplit
            + Double(txnCount) * LoadWeight.perTransaction
            + Double(priceCount) * LoadWeight.perPrice
        // An empty book still needs a denominator; 1 unit keeps the fraction
        // defined and the bar lands on 1.0 rather than NaN.
        totalWork = max(work, 1)
    }

    var transactionTotal: Int { txnCount }
    var priceTotal: Int { priceCount }

    /// Accounts and commodities together are 0.3% of a load, so they are not
    /// metered — the stage exists to caption the first instant, and the bar
    /// leaves it at whatever the splits have already earned.
    mutating func startingAccounts() {
        report(.init(stage: .accounts, completed: 0, total: 0, fraction: 0), force: true)
    }

    /// Grouping the split rows is real work (6.3% of a load) and happens before
    /// the first transaction is built, so it is reported under `transactions` —
    /// which is what it is for.
    mutating func groupedSplits(_ completed: Int) {
        let done = Double(completed) * LoadWeight.perSplit
        report(.init(stage: .transactions, completed: 0, total: txnCount,
                     fraction: done / totalWork))
    }

    mutating func startTransactions() {
        workBefore = Double(splitCount) * LoadWeight.perSplit
    }

    mutating func builtTransactions(_ completed: Int) {
        let done = workBefore + Double(completed) * LoadWeight.perTransaction
        report(.init(stage: .transactions, completed: completed, total: txnCount,
                     fraction: done / totalWork))
    }

    mutating func startPrices() {
        workBefore = Double(splitCount) * LoadWeight.perSplit
            + Double(txnCount) * LoadWeight.perTransaction
    }

    mutating func builtPrices(_ completed: Int) {
        let done = workBefore + Double(completed) * LoadWeight.perPrice
        report(.init(stage: .prices, completed: completed, total: priceCount,
                     fraction: done / totalWork))
    }

    mutating func finished() {
        report(.init(stage: .prices, completed: priceCount, total: priceCount,
                     fraction: 1), force: true)
    }

    /// Emits at most once per whole percent. `force` is for the endpoints, which
    /// must be seen even if they round to a percent already reported.
    private mutating func report(_ progress: BookLoadProgress, force: Bool = false) {
        let percent = Int((progress.fraction * 100).rounded(.down))
        guard force || percent > lastPercent else { return }
        lastPercent = percent
        emit(progress)
    }
}

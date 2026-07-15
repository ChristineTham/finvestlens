//
//  LiveRefreshPerfTests.swift
//  FinvestLens — FeatureUI
//
//  Per-edit performance harness against a **real** book supplied via the
//  FL_PERF_FILE environment variable; skipped when unset, so CI stays
//  deterministic. Run as:
//
//      FL_PERF_FILE="/path/to/Book.finvestlens" \
//          swift test -c release --filter LiveRefreshPerfTests
//
//  `refreshAll()` runs after every mutation, so its cost *is* the cost of an
//  edit. This reports the whole-open cost and the steady-state refresh cost so
//  a change to derived state can be judged against a measurement.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

private let perfPath = ProcessInfo.processInfo.environment["FL_PERF_FILE"]

@MainActor
@Suite(.serialized)
struct LiveRefreshPerfTests {

    @Test("refreshAll cost per edit")
    func refreshCost() async throws {
        guard let perfPath else { return }

        // Work on a copy: the harness must never touch the live book.
        let source = URL(fileURLWithPath: perfPath)
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("flperf-\(UUID().uuidString).finvestlens")
        try FileManager.default.copyItem(at: source, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }

        let clock = ContinuousClock()
        let model = AppModel()

        let openTime = try await clock.measure { try await model.open(at: copy) }
        defer { model.close() }

        // Steady-state refresh, general ledger (no account selected).
        var refreshNoSelection = Duration.zero
        for _ in 0..<3 { refreshNoSelection = clock.measure { model.refreshAll() } }

        // Steady-state refresh with the largest account selected — this is what
        // a register edit actually pays.
        let book = model.book!
        let busiest = book.accounts.max { book.splits(for: $0).count < book.splits(for: $1).count }!
        model.selectedAccountID = busiest.guid
        var refreshSelected = Duration.zero
        for _ in 0..<3 { refreshSelected = clock.measure { model.refreshAll() } }

        print("""

        === refreshAll on \(source.lastPathComponent) ===
        open (whole)        : \(openTime)
        refreshAll (ledger) : \(refreshNoSelection)
        refreshAll (register, \(busiest.name), \(book.splits(for: busiest).count) splits) : \(refreshSelected)
        priceRows           : \(model.priceRows.count)
        rateRows            : \(model.rateRows.count)

        """)
    }
}

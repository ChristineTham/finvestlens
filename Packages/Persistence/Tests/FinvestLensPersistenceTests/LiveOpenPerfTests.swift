//
//  LiveOpenPerfTests.swift
//  FinvestLens — Persistence
//
//  Open-path performance harness against a **real** book supplied via the
//  FL_PERF_FILE environment variable; skipped when unset, so CI stays
//  deterministic. Run as:
//
//      FL_PERF_FILE="/path/to/Book.finvestlens" \
//          swift test --filter LiveOpenPerfTests
//
//  Reports the wall-clock split between the working-copy copy, `store.read`,
//  and the fingerprint, so a change to the open path can be judged against a
//  measurement rather than an assumption.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensPersistence

private let perfPath = ProcessInfo.processInfo.environment["FL_PERF_FILE"]

@Suite(.serialized)
struct LiveOpenPerfTests {

    @Test("open path phase timings")
    func openPhases() throws {
        guard let perfPath else { return }
        let url = URL(fileURLWithPath: perfPath)

        let clock = ContinuousClock()

        // Phase 1: the working-copy file copy.
        let workingCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent("flperf-\(UUID().uuidString).finvestlens")
        let copyTime = try clock.measure {
            try FileManager.default.copyItem(at: url, to: workingCopy)
        }
        defer { try? FileManager.default.removeItem(at: workingCopy) }

        // Phase 2: opening the SQLite store.
        var store: SQLiteDocumentStore?
        let storeTime = try clock.measure {
            store = try SQLiteDocumentStore(path: workingCopy.path)
        }

        // Phase 3: materialising the book — the phase under investigation.
        var book: Book?
        let readTime = try clock.measure {
            book = try store!.read()
        }

        // Phase 4: the price sort `refreshAll()` pays on every mutation.
        let loaded = book!
        var sortTime = Duration.zero
        for _ in 0..<3 {
            sortTime = clock.measure {
                let sorted = loaded.prices.sorted { $0.date > $1.date }
                blackHole(sorted.count)
            }
        }

        print("""

        === open phases on \(url.lastPathComponent) ===
        working copy : \(copyTime)
        store init   : \(storeTime)
        store.read   : \(readTime)
        price sort   : \(sortTime)
        accounts     : \(loaded.rootAccount.descendants.count)
        transactions : \(loaded.transactions.count)
        prices       : \(loaded.prices.count)

        """)
    }
}

@inline(never) private func blackHole(_ value: Int) { if value == Int.min { print(value) } }

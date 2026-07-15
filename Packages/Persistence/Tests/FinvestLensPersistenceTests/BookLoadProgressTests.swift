//
//  BookLoadProgressTests.swift
//  FinvestLens — Persistence
//
//  Progress reporting through a book load.
//
//  The properties that matter are the ones a user would notice: the bar only
//  ever moves forward, it ends at exactly 1, and it does not lie about pace —
//  a book that is mostly prices must spend most of the bar in prices.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensPersistence

@Suite("Book load progress")
struct BookLoadProgressTests {

    /// A book with `txnCount` transactions (one split each) and `priceCount`
    /// prices, written to a scratch store and read back.
    private func store(txnCount: Int, priceCount: Int) throws -> SQLiteDocumentStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("progress-\(UUID().uuidString).finvestlens")
        let store = try SQLiteDocumentStore(path: url.path)
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let stock = Commodity(namespace: .security("ASX"), mnemonic: "BHP",
                              fullName: "BHP", smallestFraction: 10000)

        for i in 0..<txnCount {
            let txn = Transaction(currency: .aud,
                                  datePosted: Date(timeIntervalSince1970: Double(i)))
            txn.addSplit(account: bank, value: 1)
            book.addTransaction(txn)
        }
        for i in 0..<priceCount {
            book.addPrice(Price(commodity: stock, currency: .aud,
                                date: Date(timeIntervalSince1970: Double(i)), value: 42))
        }
        try store.write(book)
        return store
    }

    /// Collects every report a read emits.
    private func reports(from store: SQLiteDocumentStore) throws -> [BookLoadProgress] {
        // The callback is `@Sendable` and called synchronously on this thread;
        // a lock keeps that promise honest without pulling in an actor.
        let box = Box()
        _ = try store.read { box.append($0) }
        return box.values
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [BookLoadProgress] = []
        func append(_ p: BookLoadProgress) { lock.lock(); storage.append(p); lock.unlock() }
        var values: [BookLoadProgress] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    @Test("A read with no observer still produces the same book")
    func unobservedReadIsUnchanged() throws {
        let store = try store(txnCount: 10, priceCount: 10)
        let book = try store.read()
        #expect(book.transactions.count == 10)
        #expect(book.prices.count == 10)
    }

    @Test("Progress never goes backwards and ends at exactly 1")
    func monotonicAndComplete() throws {
        let all = try reports(from: try store(txnCount: 200, priceCount: 200))
        #expect(!all.isEmpty)
        #expect(zip(all, all.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
        #expect(all.last?.fraction == 1.0)
        #expect(all.allSatisfy { $0.fraction >= 0 && $0.fraction <= 1 })
    }

    /// Pins the measured weights (24µs a split, 9µs a transaction, 26µs a price)
    /// by asserting exactly where the prices stage starts.
    ///
    /// The numbers are literals rather than ``LoadWeight`` on purpose: reading
    /// the constants back would make this circular, and pass whatever they were
    /// changed to. With one split per transaction and equal counts:
    ///
    ///     transactions: 1000×24 + 1000×9 = 33,000
    ///     prices:       1000×26          = 26,000
    ///     prices start at 33,000 / 59,000 = 0.559
    ///
    /// Counting rows instead of weighting them — the obvious implementation —
    /// puts this at 2000/3000 = 0.667, so this test is what stands between the
    /// two. It is worth the tightness: an 11-point error is a bar that visibly
    /// runs fast and then stalls.
    @Test("Stage boundaries follow the measured per-row costs, not row counts")
    func stageBoundariesUseMeasuredWeights() throws {
        let all = try reports(from: try store(txnCount: 1000, priceCount: 1000))
        let priceStart = try #require(all.first { $0.stage == .prices }).fraction
        #expect(abs(priceStart - 0.559) < 0.01,
                "prices should start at ~0.559 (weighted), not 0.667 (row-counted); got \(priceStart)")
    }

    /// A book that is overwhelmingly prices must spend the bar in prices.
    @Test("A price-heavy book spends most of the bar in prices")
    func priceHeavyBookIsWeightedTowardPrices() throws {
        let all = try reports(from: try store(txnCount: 100, priceCount: 5000))
        let priceStart = try #require(all.first { $0.stage == .prices }).fraction
        // 100×24 + 100×9 = 3,300 against 5000×26 = 130,000 → 2.5%.
        #expect(priceStart < 0.05)
    }

    @Test("A transaction-heavy book spends most of the bar in transactions")
    func txnHeavyBookIsWeightedTowardTransactions() throws {
        let all = try reports(from: try store(txnCount: 5000, priceCount: 100))
        let priceStart = try #require(all.first { $0.stage == .prices }).fraction
        #expect(priceStart > 0.9)
    }

    @Test("Stages arrive in order, each reporting its own total")
    func stagesAreOrdered() throws {
        let all = try reports(from: try store(txnCount: 50, priceCount: 50))
        let order = all.map(\.stage)
        #expect(order.first == .accounts)
        #expect(order.last == .prices)
        // No stage reappears once the next has started.
        let firstPrice = try #require(order.firstIndex(of: .prices))
        #expect(!order[firstPrice...].contains(.transactions))

        let txnReports = all.filter { $0.stage == .transactions && $0.completed > 0 }
        #expect(txnReports.allSatisfy { $0.total == 50 })
        #expect(all.filter { $0.stage == .prices }.allSatisfy { $0.total == 50 })
    }

    /// An empty book divides by its own work total, which is zero.
    @Test("An empty book completes rather than dividing by zero")
    func emptyBook() throws {
        let all = try reports(from: try store(txnCount: 0, priceCount: 0))
        #expect(all.last?.fraction == 1.0)
        #expect(all.allSatisfy { $0.fraction.isFinite })
    }

    /// `finishing` belongs to the caller, not the store: it covers the
    /// main-actor work after the read. The store must never emit it, or the bar
    /// would claim the read was over while it was still running.
    @Test("The store never reports the finishing stage")
    func storeDoesNotReportFinishing() throws {
        let all = try reports(from: try store(txnCount: 100, priceCount: 100))
        #expect(!all.contains { $0.stage == .finishing })
    }

    /// ~250,000 rows must not mean 250,000 reports: the hop to the main actor
    /// would cost more than the load.
    @Test("Reporting is throttled to about one per percent")
    func reportingIsThrottled() throws {
        let all = try reports(from: try store(txnCount: 2000, priceCount: 2000))
        #expect(all.count <= 105, "expected ~100 reports, got \(all.count)")
    }
}

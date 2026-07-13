//
//  LiveFileRoundTripTests.swift
//  FinvestLens — Interchange
//
//  Deep round-trip fidelity harness (`FR-EXP-02`) against a **real** GnuCash
//  file supplied via the FL_ROUNDTRIP_FILE environment variable; skipped when
//  unset, so CI stays deterministic. Run as:
//
//      FL_ROUNDTRIP_FILE="/path/to/Book.gnucash" \
//          swift test --filter LiveFileRoundTripTests
//
//  Compares the full object graph (accounts, transactions, splits, prices,
//  balances, GUIDs, KVP) between the first and second import, and requires
//  the double export to be byte-identical.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensInterchange

private let livePath = ProcessInfo.processInfo.environment["FL_ROUNDTRIP_FILE"]

@Suite("Live file round-trip")
struct LiveFileRoundTripTests {

    @Test("Import → export → re-import preserves the full graph",
          .enabled(if: livePath != nil))
    func fullRoundTrip() throws {
        let url = URL(fileURLWithPath: livePath!)
        var failures: [String] = []
        func check(_ ok: Bool, _ label: String) {
            if !ok { failures.append(label) }
        }

        // ── Pass 1: import the original ────────────────────────────────
        let t0 = Date()
        let first = try GnuCashXMLImporter.importBook(from: url)
        let importSecs = Date().timeIntervalSince(t0)
        let s = first.summary
        print("IMPORT  \(String(format: "%.1f", importSecs))s — " +
              "accounts \(s.accountCount), transactions \(s.transactionCount), " +
              "splits \(s.splitCount), commodities \(s.commodityCount), prices \(s.priceCount)")
        print("WARNINGS \(s.warnings.count)")
        for w in Set(s.warnings).sorted().prefix(12) { print("  • \(w)") }
        print("SCRUB ISSUES \(s.scrubIssues.count)")
        for i in s.scrubIssues.prefix(12) { print("  • \(i)") }

        // ── Export pass 1 ──────────────────────────────────────────────
        let t1 = Date()
        let xml1 = GnuCashXMLExporter.export(first.book)
        print("EXPORT  \(String(format: "%.1f", Date().timeIntervalSince(t1)))s — \(xml1.count) bytes")

        // ── Pass 2: re-import the export ───────────────────────────────
        let t2 = Date()
        let second = try GnuCashXMLImporter.importBook(from: xml1)
        print("REIMPORT \(String(format: "%.1f", Date().timeIntervalSince(t2)))s")
        let b1 = first.book, b2 = second.book

        // ── Deep graph comparison ──────────────────────────────────────
        check(b1.guid == b2.guid, "book GUID")
        check(b1.kvp == b2.kvp, "book KVP")
        check(Set(b1.commodities) == Set(b2.commodities),
              "commodities (\(b1.commodities.count) vs \(b2.commodities.count))")

        // Accounts by GUID.
        let a1 = Dictionary(uniqueKeysWithValues: b1.accounts.map { ($0.guid, $0) })
        let a2 = Dictionary(uniqueKeysWithValues: b2.accounts.map { ($0.guid, $0) })
        check(a1.count == a2.count, "account count (\(a1.count) vs \(a2.count))")
        var accountDiffs = 0
        for (guid, x) in a1 {
            guard let y = a2[guid] else { accountDiffs += 1; continue }
            if x.name != y.name || x.type != y.type || x.code != y.code
                || x.accountDescription != y.accountDescription || x.notes != y.notes
                || x.commodity != y.commodity || x.parent?.guid != y.parent?.guid
                || x.isPlaceholder != y.isPlaceholder || x.isHidden != y.isHidden
                || x.kvp != y.kvp {
                accountDiffs += 1
                if accountDiffs <= 5 { print("  ✗ account \(x.fullName)") }
            }
        }
        check(accountDiffs == 0, "accounts identical (\(accountDiffs) differ)")

        // Transactions + splits by GUID.
        let t1s = Dictionary(uniqueKeysWithValues: b1.transactions.map { ($0.guid, $0) })
        let t2s = Dictionary(uniqueKeysWithValues: b2.transactions.map { ($0.guid, $0) })
        check(t1s.count == t2s.count, "transaction count (\(t1s.count) vs \(t2s.count))")
        var txnDiffs = 0, splitDiffs = 0
        for (guid, x) in t1s {
            guard let y = t2s[guid] else { txnDiffs += 1; continue }
            if x.currency != y.currency || x.datePosted != y.datePosted
                || x.number != y.number || x.transactionDescription != y.transactionDescription
                || x.notes != y.notes || x.kvp != y.kvp {
                txnDiffs += 1
                if txnDiffs <= 5 { print("  ✗ txn \(x.transactionDescription) @ \(x.datePosted)") }
            }
            let sp1 = Dictionary(uniqueKeysWithValues: x.splits.map { ($0.guid, $0) })
            let sp2 = Dictionary(uniqueKeysWithValues: y.splits.map { ($0.guid, $0) })
            if sp1.count != sp2.count { splitDiffs += 1; continue }
            for (sg, sx) in sp1 {
                guard let sy = sp2[sg] else { splitDiffs += 1; continue }
                if sx.account?.guid != sy.account?.guid || sx.value != sy.value
                    || sx.quantity != sy.quantity || sx.memo != sy.memo
                    || sx.action != sy.action || sx.reconcileState != sy.reconcileState
                    || sx.reconcileDate != sy.reconcileDate || sx.kvp != sy.kvp {
                    splitDiffs += 1
                    if splitDiffs <= 5 {
                        print("  ✗ split in \(x.transactionDescription): value \(sx.value) vs \(sy.value)")
                    }
                }
            }
        }
        check(txnDiffs == 0, "transactions identical (\(txnDiffs) differ)")
        check(splitDiffs == 0, "splits identical (\(splitDiffs) differ)")

        // Prices by GUID.
        let p1 = Dictionary(uniqueKeysWithValues: b1.prices.map { ($0.guid, $0) })
        let p2 = Dictionary(uniqueKeysWithValues: b2.prices.map { ($0.guid, $0) })
        check(p1.count == p2.count, "price count (\(p1.count) vs \(p2.count))")
        var priceDiffs = 0
        for (guid, x) in p1 {
            guard let y = p2[guid],
                  x.commodity == y.commodity, x.currency == y.currency,
                  x.date == y.date, x.value == y.value,
                  x.source == y.source, x.type == y.type else { priceDiffs += 1; continue }
        }
        check(priceDiffs == 0, "prices identical (\(priceDiffs) differ)")

        // Per-account balances.
        let t3 = Date()
        var balanceDiffs = 0
        for (guid, x) in a1 {
            guard let y = a2[guid] else { continue }
            if b1.balance(of: x).rounded.amount != b2.balance(of: y).rounded.amount {
                balanceDiffs += 1
                if balanceDiffs <= 5 { print("  ✗ balance \(x.fullName)") }
            }
        }
        check(balanceDiffs == 0, "balances identical (\(balanceDiffs) differ)")
        print("BALANCES \(String(format: "%.1f", Date().timeIntervalSince(t3)))s — \(a1.count) accounts compared")

        // ── Determinism: export pass 2 must be byte-identical ──────────
        let xml2 = GnuCashXMLExporter.export(b2)
        check(xml1 == xml2, "double export byte-identical (\(xml1.count) vs \(xml2.count) bytes)")

        print(failures.isEmpty
              ? "ROUND-TRIP CLEAN — all checks passed"
              : "ROUND-TRIP FAILURES: \(failures.joined(separator: "; "))")
        #expect(failures.isEmpty)
    }
}

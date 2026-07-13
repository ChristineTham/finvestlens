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

/// Removes the scheduled-transaction and budget sections (documented
/// non-goals of the XML round-trip) before inventory comparison.
private func stripped(_ xml: String) -> String {
    var out = xml
    for (open, close) in [("<gnc:template-transactions>", "</gnc:template-transactions>"),
                          ("<gnc:schedxaction", "</gnc:schedxaction>"),
                          ("<gnc:budget", "</gnc:budget>")] {
        while let start = out.range(of: open),
              let end = out.range(of: close, range: start.upperBound..<out.endIndex) {
            out.removeSubrange(start.lowerBound..<end.upperBound)
        }
    }
    return out
}

private func occurrences(of needle: String, in text: String) -> Int {
    var count = 0
    var cursor = text.startIndex
    while let found = text.range(of: needle, range: cursor..<text.endIndex) {
        count += 1
        cursor = found.upperBound
    }
    return count
}

/// Multiset of `<slot:key>` values in the document, entity-decoded so raw
/// and escaped forms of the same key compare equal.
private func slotKeyCounts(in text: String) -> [String: Int] {
    var counts: [String: Int] = [:]
    var cursor = text.startIndex
    while let open = text.range(of: "<slot:key>", range: cursor..<text.endIndex) {
        guard let close = text.range(of: "</slot:key>", range: open.upperBound..<text.endIndex) else { break }
        let key = String(text[open.upperBound..<close.lowerBound])
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        counts[key, default: 0] += 1
        cursor = close.upperBound
    }
    return counts
}

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

        // Commodity == is identity (namespace+mnemonic), so compare fields.
        let c1 = Dictionary(uniqueKeysWithValues: b1.commodities.map { ("\($0.namespace)|\($0.mnemonic)", $0) })
        let c2 = Dictionary(uniqueKeysWithValues: b2.commodities.map { ("\($0.namespace)|\($0.mnemonic)", $0) })
        check(c1.count == c2.count, "commodity count (\(c1.count) vs \(c2.count))")
        var commodityDiffs = 0
        for (key, x) in c1 {
            guard let y = c2[key],
                  x.fullName == y.fullName, x.smallestFraction == y.smallestFraction,
                  x.exchangeCode == y.exchangeCode, x.getQuotes == y.getQuotes,
                  x.quoteSource == y.quoteSource, x.quoteTimezone == y.quoteTimezone,
                  x.kvp == y.kvp
            else {
                commodityDiffs += 1
                if commodityDiffs <= 5 { print("  ✗ commodity \(key)") }
                continue
            }
        }
        check(commodityDiffs == 0, "commodities identical (\(commodityDiffs) differ)")

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

        // ── Faithfulness to the ORIGINAL file ──────────────────────────
        // Import-vs-import comparison can't see data dropped at import time,
        // so also compare content inventories between the original XML and
        // the export. Scheduled-transaction (template + sx) and budget
        // sections are stripped from the original first — they are a
        // documented non-goal (kept in FinvestLens' own KVP form instead).
        let t4 = Date()
        let originalXML = stripped(String(decoding: try Gzip.decompressIfNeeded(Data(contentsOf: url)),
                                          as: UTF8.self))
        let exportedXML = stripped(String(decoding: xml1, as: UTF8.self))

        for tag in ["<gnc:account version", "<gnc:transaction version", "<price>",
                    "<cmdty:get_quotes", "<cmdty:xcode", "<cmdty:quote_source",
                    "<cmdty:quote_tz"] {
            let inOriginal = occurrences(of: tag, in: originalXML)
            let inExport = occurrences(of: tag, in: exportedXML)
            check(inOriginal == inExport, "\(tag) count (\(inOriginal) vs \(inExport))")
        }
        let originalKeys = slotKeyCounts(in: originalXML)
        let exportedKeys = slotKeyCounts(in: exportedXML)
        if originalKeys != exportedKeys {
            let allKeys = Set(originalKeys.keys).union(exportedKeys.keys)
            for key in allKeys.sorted() where originalKeys[key] != exportedKeys[key] {
                print("  ✗ slot '\(key)': original \(originalKeys[key] ?? 0), export \(exportedKeys[key] ?? 0)")
            }
        }
        check(originalKeys == exportedKeys,
              "slot-key inventory (\(originalKeys.values.reduce(0, +)) vs \(exportedKeys.values.reduce(0, +)) slots)")
        print("INVENTORY \(String(format: "%.1f", Date().timeIntervalSince(t4)))s — " +
              "\(originalKeys.values.reduce(0, +)) slots compared against the original")

        print(failures.isEmpty
              ? "ROUND-TRIP CLEAN — all checks passed"
              : "ROUND-TRIP FAILURES: \(failures.joined(separator: "; "))")
        #expect(failures.isEmpty)
    }
}

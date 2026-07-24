//
//  LiveBankImportTests.swift
//  FinvestLens — FeatureUI
//
//  End-to-end validation of the bank-statement import pipeline against a real
//  book and the user's real statement exports; skipped unless both are
//  supplied, so CI stays deterministic. Run as:
//
//      FL_PERF_FILE="/path/to/Book.finvestlens" \
//          FL_IMPORT_DIR="/path/to/imports" \
//          swift test --filter LiveBankImportTests
//
//  FL_IMPORT_DIR must hold "ANZ VISA.ofx", "CDIA.ofx", "CMA.qif", "CMAA.qif".
//  The scenario the four files encode: two ANZ-card payments funded from CDIA
//  (8 Jun and 11 May 2026) and one SMSF internal transfer CMAA → CMA (20 May
//  2026). Importing all four statements — in either order — must leave each
//  transfer as ONE transaction with a leg in each account: no mirror-image
//  duplicates, no legs left in a wash account. Re-importing every file must
//  then be a no-op.
//
//  Works on a copy: the harness must never touch the live book.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensInterchange
@testable import FinvestLensUI

private let perfPath = ProcessInfo.processInfo.environment["FL_PERF_FILE"]
private let importDir = ProcessInfo.processInfo.environment["FL_IMPORT_DIR"]

private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var c = DateComponents(); c.year = y; c.month = m; c.day = d
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: c)!
}

@MainActor
@Suite(.serialized)
struct LiveBankImportTests {

    /// (file, account name in the book, format, expected row count)
    private static let statements: [(file: String, account: String, format: BankFileFormat, rows: Int)] = [
        ("ANZ VISA.ofx", "ANZ VISA", .ofx, 220),
        ("CDIA.ofx", "CDIA", .ofx, 58),
        ("CMA.qif", "CMA", .qif, 39),
        ("CMAA.qif", "CMAA", .qif, 3),
    ]

    @Test("Four real statements import with transfers matched, in either order")
    func fourStatementsBothOrders() async throws {
        guard let perfPath, let importDir else { return }
        try await run(order: [0, 1, 2, 3], perfPath: perfPath, importDir: importDir)   // VISA → CDIA → CMA → CMAA
        try await run(order: [3, 2, 1, 0], perfPath: perfPath, importDir: importDir)   // CMAA → CMA → CDIA → VISA
    }

    private func run(order: [Int], perfPath: String, importDir: String) async throws {
        let source = URL(fileURLWithPath: perfPath)
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("flimport-\(UUID().uuidString).finvestlens")
        try FileManager.default.copyItem(at: source, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }

        let model = AppModel()
        await model.openBook(at: copy, breakStaleLock: true)
        defer { model.close() }
        let book = try #require(model.book)

        func account(_ name: String) -> Account? {
            book.accounts.first { $0.name == name }
        }

        // Import each statement once, in the given order.
        for index in order {
            let statement = Self.statements[index]
            let url = URL(fileURLWithPath: importDir).appendingPathComponent(statement.file)
            let data = try Data(contentsOf: url)
            let staged = model.parseBankFile(data, format: statement.format)
            #expect(staged.count == statement.rows, "\(statement.file) parsed \(staged.count) rows")
            // Every date must land in the statement window (a two-digit-year
            // bug would put QIF rows in year 26 AD).
            #expect(staged.allSatisfy { $0.date >= day(2026, 4, 20) && $0.date <= day(2026, 7, 2) },
                    "\(statement.file) dates out of range")

            let target = try #require(account(statement.account), "no account \(statement.account)")
            let results = model.matchStaged(staged, intoAccountID: target.guid)
            let duplicates = results.filter(\.isDuplicate).count
            let transfers = results.filter { $0.transferSplitID != nil }.count
            let categorised = results.filter {
                !$0.isDuplicate && $0.transferSplitID == nil && $0.suggestedAccountID != nil
            }.count
            let unmatched = staged.count - duplicates - transfers - categorised
            print("📥 \(statement.file): \(staged.count) rows — \(duplicates) duplicate, "
                  + "\(transfers) transfer-matched, \(categorised) auto-categorised, "
                  + "\(unmatched) → Imbalance")
            let fmt = { (d: Date) in d.formatted(.iso8601.year().month().day()) }
            for result in results where result.isDuplicate {
                let row = result.staged
                let matched = result.matchedSplitID.flatMap { book.split(with: $0) }
                let txn = matched?.transaction
                print("   ↩︎ dup \(fmt(row.date)) \(row.amount) \(String((row.payee.isEmpty ? row.memo : row.payee).prefix(44)))"
                      + " ⇒ \(txn.map { fmt($0.datePosted) } ?? "?") \(String((txn?.transactionDescription ?? "?").prefix(44)))")
            }
            for result in results where result.transferSplitID != nil {
                let row = result.staged
                print("   ⇄ transfer \(fmt(row.date)) \(row.amount) \(String((row.payee.isEmpty ? row.memo : row.payee).prefix(44)))")
            }
            let imported = model.importMatched(results, intoAccountID: target.guid,
                                               fallbackToImbalance: true)
            // With the imbalance fallback, everything that isn't a duplicate imports.
            #expect(imported == staged.count - duplicates,
                    "\(statement.file): imported \(imported) of \(staged.count) (\(duplicates) duplicates)")
        }

        // The three cross-account transfers exist exactly once, with a leg in
        // each account and none left in a wash account.
        let visa = try #require(account("ANZ VISA"))
        let cdia = try #require(account("CDIA"))
        let cma = try #require(account("CMA"))
        let cmaa = try #require(account("CMAA"))
        assertSingleTransfer(book: book, from: cdia, to: visa,
                             amount: Decimal(string: "4439.95")!, around: day(2026, 6, 8))
        assertSingleTransfer(book: book, from: cdia, to: visa,
                             amount: Decimal(string: "18512.99")!, around: day(2026, 5, 11))
        assertSingleTransfer(book: book, from: cmaa, to: cma,
                             amount: Decimal(5000), around: day(2026, 5, 20))

        // Idempotency: importing every file again changes nothing.
        for statement in Self.statements {
            let url = URL(fileURLWithPath: importDir).appendingPathComponent(statement.file)
            let data = try Data(contentsOf: url)
            let staged = model.parseBankFile(data, format: statement.format)
            let target = try #require(account(statement.account))
            let results = model.matchStaged(staged, intoAccountID: target.guid)
            let nonDuplicates = results.filter { !$0.isDuplicate }.count
            #expect(nonDuplicates == 0,
                    "\(statement.file): re-import found \(nonDuplicates) non-duplicates")
            let imported = model.importMatched(results, intoAccountID: target.guid,
                                               fallbackToImbalance: true)
            #expect(imported == 0, "\(statement.file): re-import posted \(imported) rows")
        }
    }

    /// Exactly one transaction moves `amount` from `from` to `to` near `date`,
    /// clean of wash legs — and neither side has a stray mirror duplicate.
    private func assertSingleTransfer(book: Book, from: Account, to: Account,
                                      amount: Decimal, around date: Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func near(_ txnDate: Date) -> Bool {
            abs(cal.dateComponents([.day], from: txnDate, to: date).day ?? .max) <= 4
        }

        let pairs = book.transactions.filter { txn in
            near(txn.datePosted)
                && txn.splits.contains { $0.account === from && $0.value == -amount }
                && txn.splits.contains { $0.account === to && $0.value == amount }
        }
        #expect(pairs.count == 1,
                "\(from.name) → \(to.name) \(amount): found \(pairs.count) paired transactions")
        if let transfer = pairs.first {
            #expect(transfer.splits.allSatisfy { split in
                split.account.map { !ImportMatcher.isWash($0) } ?? false
            }, "transfer still touches a wash account")
        }

        // No second copy of either leg anywhere in the window (the classic
        // both-sides-imported-separately failure).
        let fromLegs = book.splits(for: from).filter {
            $0.value == -amount && ($0.transaction.map { near($0.datePosted) } ?? false)
        }
        let toLegs = book.splits(for: to).filter {
            $0.value == amount && ($0.transaction.map { near($0.datePosted) } ?? false)
        }
        #expect(fromLegs.count == 1, "\(from.name) has \(fromLegs.count) legs of \(-amount)")
        #expect(toLegs.count == 1, "\(to.name) has \(toLegs.count) legs of \(amount)")
    }
}

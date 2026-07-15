//
//  AppModel+Import.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensInterchange
import FinvestLensRules

/// Supported bank-file import formats. `pdf` statements are read by Apple
/// Intelligence (`FR-AI-01`) before reaching the shared review flow.
public enum BankFileFormat: String, Sendable, CaseIterable, Identifiable {
    case csv, qif, ofx, pdf
    public var id: String { rawValue }

    public static func forExtension(_ ext: String) -> BankFileFormat? {
        switch ext.lowercased() {
        case "csv": return .csv
        case "qif": return .qif
        case "ofx", "qfx": return .ofx
        case "pdf": return .pdf
        default: return nil
        }
    }
}

@MainActor
extension AppModel {

    /// Parses a bank file into staged transactions (`FR-XIO-01/02/03`).
    public func parseBankFile(_ data: Data, format: BankFileFormat,
                              csvMapping: CSVColumnMapping? = nil) -> [StagedTransaction] {
        switch format {
        case .csv: return CSVTransactionImporter.parse(data, mapping: csvMapping ?? CSVColumnMapping(date: 0))
        case .qif: return QIFImporter.parse(data)
        case .ofx: return OFXImporter.parse(data)
        // PDF rows are extracted asynchronously by Apple Intelligence before
        // the review sheet opens (see ImportPayload.prestaged).
        case .pdf: return []
        }
    }

    /// Matches staged rows against a target account (`FR-XIO-05`), then lets
    /// categorisation rules override the history-based suggestion (`FR-RULE-01`).
    public func matchStaged(_ staged: [StagedTransaction], intoAccountID id: GncGUID) -> [MatchResult] {
        guard let book, let account = book.account(with: id) else { return [] }
        var results = ImportMatcher.match(staged, into: account, book: book)

        let groups = ruleGroups
        for index in results.indices {
            let staged = results[index].staged
            let name = staged.payee.isEmpty ? staged.memo : staged.payee
            // Rules take precedence.
            if !groups.isEmpty {
                let outcome = RuleEngine.evaluate(groups, context: RuleContext(
                    description: name, memo: staged.memo, amount: staged.amount))
                if let account = outcome.accountID {
                    results[index].suggestedAccountID = account
                    continue
                }
            }
            // Heuristic fallback when history + rules didn't assign one.
            if results[index].suggestedAccountID == nil,
               let categoryName = MerchantHeuristics.category(for: name),
               let account = self.account(named: categoryName) {
                results[index].suggestedAccountID = account
            }
        }
        return results
    }

    /// Finds a non-placeholder account by (case-insensitive) name.
    private func account(named name: String) -> GncGUID? {
        book?.accounts.first {
            !$0.isPlaceholder && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }?.guid
    }

    /// Posts accepted rows into the book as balanced transactions: the target
    /// account gets the signed amount, the assigned (or suggested) account the
    /// opposite. Duplicates and rows without a destination are skipped.
    ///
    /// - Returns: the number of transactions created.
    @discardableResult
    public func importMatched(_ results: [MatchResult], intoAccountID id: GncGUID,
                              assignments: [UUID: GncGUID] = [:],
                              skipDuplicates: Bool = true) -> Int {
        guard let book, let target = book.account(with: id) else { return 0 }
        var created: [Transaction] = []
        for result in results {
            if skipDuplicates && result.isDuplicate { continue }
            let destinationID = assignments[result.staged.id] ?? result.suggestedAccountID
            guard let destinationID, let destination = book.account(with: destinationID) else { continue }

            let staged = result.staged
            let rawName = staged.payee.isEmpty ? staged.memo : staged.payee
            // Tidy the statement line for the transaction description.
            let name = MerchantHeuristics.cleanMerchant(rawName)
            let transaction = Transaction(currency: target.commodity, datePosted: staged.date,
                                          number: staged.reference,
                                          description: name.isEmpty ? rawName : name)
            transaction.addSplit(account: target, value: staged.amount, memo: staged.memo)
            transaction.addSplit(account: destination, value: -staged.amount)
            created.append(transaction)
        }
        let imported = created.count
        if imported > 0 {
            editing(created.map(\.guid), named: "Import Transactions") {
                for transaction in created { book.addTransaction(transaction) }
            }
        }
        return imported
    }
}

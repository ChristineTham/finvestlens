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

/// Supported bank-file import formats.
public enum BankFileFormat: String, Sendable, CaseIterable, Identifiable {
    case csv, qif, ofx
    public var id: String { rawValue }

    public static func forExtension(_ ext: String) -> BankFileFormat? {
        switch ext.lowercased() {
        case "csv": return .csv
        case "qif": return .qif
        case "ofx", "qfx": return .ofx
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
        }
    }

    /// Matches staged rows against a target account (`FR-XIO-05`), then lets
    /// categorisation rules override the history-based suggestion (`FR-RULE-01`).
    public func matchStaged(_ staged: [StagedTransaction], intoAccountID id: GncGUID) -> [MatchResult] {
        guard let book, let account = book.account(with: id) else { return [] }
        var results = ImportMatcher.match(staged, into: account, book: book)

        let groups = ruleGroups
        if !groups.isEmpty {
            for index in results.indices {
                let staged = results[index].staged
                let name = staged.payee.isEmpty ? staged.memo : staged.payee
                let outcome = RuleEngine.evaluate(groups, context: RuleContext(
                    description: name, memo: staged.memo, amount: staged.amount))
                if let account = outcome.accountID {
                    results[index].suggestedAccountID = account
                }
            }
        }
        return results
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
        var imported = 0
        for result in results {
            if skipDuplicates && result.isDuplicate { continue }
            let destinationID = assignments[result.staged.id] ?? result.suggestedAccountID
            guard let destinationID, let destination = book.account(with: destinationID) else { continue }

            let staged = result.staged
            let name = staged.payee.isEmpty ? staged.memo : staged.payee
            let transaction = Transaction(currency: target.commodity, datePosted: staged.date,
                                          number: staged.reference, description: name)
            transaction.addSplit(account: target, value: staged.amount, memo: staged.memo)
            transaction.addSplit(account: destination, value: -staged.amount)
            book.addTransaction(transaction)
            imported += 1
        }
        if imported > 0 { markDirtyAndRefresh() }
        return imported
    }
}

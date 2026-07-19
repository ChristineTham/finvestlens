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
        // Security transactions (QIF `!Type:Invst`, OFX investment blocks) are
        // not cash movements — they take the Stock-Assistant path, not the cash
        // matcher, so they never post to the wrong account here.
        let cash = staged.filter { !$0.isInvestment }
        var results = ImportMatcher.match(cash, into: account, book: book)

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

    /// The investment (security) rows among a staged batch, in file order.
    public func investmentRows(from staged: [StagedTransaction]) -> [StagedTransaction] {
        staged.filter(\.isInvestment)
    }

    /// A security account whose name or commodity ticker matches a staged
    /// investment row's security label, for pre-selecting it in the review.
    public func matchingSecurityAccount(for row: StagedTransaction) -> GncGUID? {
        guard let book, let inv = row.investment, !inv.security.isEmpty else { return nil }
        let needle = inv.security.lowercased()
        return book.accounts.first { account in
            guard account.type == .stock || account.type == .mutualFund else { return false }
            return account.name.lowercased() == needle
                || account.commodity.mnemonic.lowercased() == needle
        }?.guid
    }

    /// Creates a stock transaction from a staged investment row (`FR-XIO-01/02`),
    /// mapping its action to the Stock Assistant. Returns the new transaction's
    /// id, or `nil` for an action that can't be posted (e.g. `.other`).
    @discardableResult
    public func recordStagedInvestment(
        _ row: StagedTransaction, securityID: GncGUID?, settlementID: GncGUID?,
        incomeID: GncGUID? = nil, commissionID: GncGUID? = nil
    ) throws -> GncGUID? {
        guard let inv = row.investment else { return nil }
        let action: StockActionKind
        switch inv.action {
        case .buy: action = .buy
        case .sell: action = .sell
        case .dividend: action = .dividend
        case .reinvestDividend: action = .reinvestDividend
        case .other: return nil
        }

        // A commission needs a commission account to post to and stay balanced.
        // When none is given (the common import case), fold the fee into the
        // per-share cost — it becomes part of the buy's cost basis, or nets off a
        // sell's proceeds — so the transaction still balances.
        var price = inv.pricePerShare
        var commission = inv.commission
        if commissionID == nil, commission != 0, inv.quantity != 0,
           action == .buy || action == .sell {
            let perShare = commission / inv.quantity
            price += (action == .buy) ? perShare : -perShare
            commission = 0
        }

        return try recordStockTransaction(
            action: action, securityID: securityID, settlementID: settlementID,
            incomeID: incomeID, commissionID: commissionID,
            shares: inv.quantity, pricePerShare: price,
            amount: abs(row.amount), commission: commission,
            date: row.date,
            description: inv.security.isEmpty ? "Imported investment" : inv.security,
            memo: row.memo)
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
            let staged = result.staged
            let rawName = staged.payee.isEmpty ? staged.memo : staged.payee
            // Tidy the statement line for the transaction description.
            let name = MerchantHeuristics.cleanMerchant(rawName)

            // A split record (QIF `S`/`E`/`$`) posts one leg per category, when
            // every category resolves to an account; otherwise it falls back to
            // the single assigned/suggested destination below.
            if staged.isSplit {
                let legs = staged.splits.map { ($0, account(named: $0.category).flatMap { book.account(with: $0) }) }
                if legs.allSatisfy({ $0.1 != nil }) {
                    let transaction = Transaction(currency: target.commodity, datePosted: staged.date,
                                                  number: staged.reference,
                                                  description: name.isEmpty ? rawName : name)
                    let targetSplit = transaction.addSplit(account: target, value: staged.amount, memo: staged.memo)
                    if !staged.reference.isEmpty {
                        targetSplit.kvp["online_id"] = .string(staged.reference)
                    }
                    for (leg, categoryAccount) in legs {
                        transaction.addSplit(account: categoryAccount!, value: -leg.amount, memo: leg.memo)
                    }
                    created.append(transaction)
                    continue
                }
            }

            let destinationID = assignments[staged.id] ?? result.suggestedAccountID
            guard let destinationID, let destination = book.account(with: destinationID) else { continue }

            let transaction = Transaction(currency: target.commodity, datePosted: staged.date,
                                          number: staged.reference,
                                          description: name.isEmpty ? rawName : name)
            let targetSplit = transaction.addSplit(account: target, value: staged.amount, memo: staged.memo)
            // Record the bank's FITID in the split's `online_id` slot, GnuCash's
            // convention, so a re-import (here or in GnuCash) recognises it.
            if !staged.reference.isEmpty {
                targetSplit.kvp["online_id"] = .string(staged.reference)
            }
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

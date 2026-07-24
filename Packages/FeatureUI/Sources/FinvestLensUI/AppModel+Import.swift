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
/// Intelligence (`FR-AI-01`) before reaching the shared review flow;
/// `mt940` covers SWIFT MT940/MT942, `camt` ISO 20022 CAMT.053/052
/// (`FR-XIO-04`).
public enum BankFileFormat: String, Sendable, CaseIterable, Identifiable {
    case csv, qif, ofx, mt940, camt, pdf
    public var id: String { rawValue }

    public static func forExtension(_ ext: String) -> BankFileFormat? {
        switch ext.lowercased() {
        case "csv": return .csv
        case "qif": return .qif
        case "ofx", "qfx": return .ofx
        case "sta", "mt940", "940", "mt942", "942", "fin": return .mt940
        case "camt", "c52", "c53", "c54": return .camt
        case "pdf": return .pdf
        default: return nil
        }
    }

    /// Detects the format from the extension, falling back to sniffing the
    /// content — a `.xml` file may be a CAMT statement, a `.txt` an MT940.
    public static func detect(_ data: Data, extension ext: String) -> BankFileFormat? {
        if let known = forExtension(ext) { return known }
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        if head.contains("<BkToCstmrStmt") || head.contains("<BkToCstmrAcctRpt")
            || head.contains("urn:iso:std:iso:20022:tech:xsd:camt.05") {
            return .camt
        }
        if head.contains("OFXHEADER") || head.contains("<OFX") { return .ofx }
        if head.contains(":20:"), head.contains(":25:") { return .mt940 }
        if head.contains("!Type:") { return .qif }
        return nil
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
        case .mt940: return MT940Importer.parse(data)
        case .camt: return CAMTImporter.parse(data)
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
            // A detected transfer counterpart outranks rules and heuristics:
            // the amount + date + wash-leg evidence is stronger than any payee
            // text, and re-categorising it would duplicate the transaction.
            guard results[index].transferSplitID == nil else { continue }
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
    /// opposite. Duplicates are skipped (stamping their statement reference on
    /// the matched split for exact re-import matching); a row that completes a
    /// cross-account transfer re-points the existing wash leg here instead of
    /// posting a mirror duplicate; rows without a destination go to the book's
    /// imbalance account when `fallbackToImbalance` (so the Uncategorised
    /// review can sweep them), else are skipped.
    ///
    /// - Returns: the number of rows imported (created + transfer-completed).
    @discardableResult
    public func importMatched(_ results: [MatchResult], intoAccountID id: GncGUID,
                              assignments: [UUID: GncGUID] = [:],
                              skipDuplicates: Bool = true,
                              fallbackToImbalance: Bool = false) -> Int {
        guard let book, let target = book.account(with: id) else { return 0 }
        let imbalance = fallbackToImbalance ? imbalanceFallback(for: target) : nil
        var created: [Transaction] = []
        // Existing wash legs to re-point at the target (the other half of a
        // transfer the counterpart statement already created), and existing
        // matched splits to stamp with the incoming statement reference.
        var healed: [(split: Split, staged: StagedTransaction)] = []
        var referenced: [(split: Split, reference: String)] = []
        for result in results {
            if skipDuplicates && result.isDuplicate {
                if !result.staged.reference.isEmpty, let matchID = result.matchedSplitID,
                   let split = book.split(with: matchID), split.kvp["online_id"] == nil {
                    referenced.append((split, result.staged.reference))
                }
                continue
            }
            let staged = result.staged

            // Transfer completion: re-point the counterpart transaction's wash
            // leg at this account — unless the user overrode the destination,
            // which turns the row back into an ordinary new transaction.
            if let washID = result.transferSplitID,
               assignments[staged.id] == nil || assignments[staged.id] == result.suggestedAccountID,
               let wash = book.split(with: washID), wash.transaction != nil,
               let washAccount = wash.account, ImportMatcher.isWash(washAccount) {
                healed.append((wash, staged))
                continue
            }
            let rawName = staged.payee.isEmpty ? staged.memo : staged.payee
            // Tidy the statement line for the transaction description. The raw
            // narrative goes into the money leg's memo (the smart categoriser's
            // convention) so cleaning never loses it — history matching and
            // future re-imports rely on the raw text surviving somewhere.
            let name = MerchantHeuristics.cleanMerchant(rawName)
            let narrative = staged.memo.isEmpty ? rawName : staged.memo

            // A split record (QIF `S`/`E`/`$`) posts one leg per category, when
            // every category resolves to an account; otherwise it falls back to
            // the single assigned/suggested destination below.
            if staged.isSplit {
                let legs = staged.splits.map { ($0, account(named: $0.category).flatMap { book.account(with: $0) }) }
                if legs.allSatisfy({ $0.1 != nil }) {
                    let transaction = Transaction(currency: target.commodity, datePosted: staged.date,
                                                  number: staged.reference,
                                                  description: name.isEmpty ? rawName : name)
                    let targetSplit = transaction.addSplit(
                        account: target, value: staged.amount,
                        memo: name == rawName ? staged.memo : narrative)
                    if !staged.reference.isEmpty {
                        targetSplit.kvp["online_id"] = .string(staged.reference)
                    }
                    for (leg, categoryAccount) in legs {
                        transaction.addSplit(account: categoryAccount!, value: -leg.amount, memo: leg.memo)
                    }
                    // Only accept the split when the legs actually sum to the row
                    // total; a malformed file (legs ≠ `T`) falls back to the
                    // single-destination path rather than posting an imbalance.
                    if transaction.isBalanced {
                        created.append(transaction)
                        continue
                    }
                }
            }

            let destinationID = assignments[staged.id] ?? result.suggestedAccountID
            guard let destination = destinationID.flatMap({ book.account(with: $0) }) ?? imbalance
            else { continue }

            let transaction = Transaction(currency: target.commodity, datePosted: staged.date,
                                          number: staged.reference,
                                          description: name.isEmpty ? rawName : name)
            let targetSplit = transaction.addSplit(
                account: target, value: staged.amount,
                memo: name == rawName ? staged.memo : narrative)
            // Record the bank's FITID in the split's `online_id` slot, GnuCash's
            // convention, so a re-import (here or in GnuCash) recognises it.
            if !staged.reference.isEmpty {
                targetSplit.kvp["online_id"] = .string(staged.reference)
            }
            transaction.addSplit(account: destination, value: -staged.amount)
            created.append(transaction)
        }
        let imported = created.count + healed.count
        let touched = created.map(\.guid)
            + healed.compactMap { $0.split.transaction?.guid }
            + referenced.compactMap { $0.split.transaction?.guid }
        if !touched.isEmpty {
            editing(touched, named: "Import Transactions") {
                for transaction in created { book.addTransaction(transaction) }
                for (split, staged) in healed {
                    split.account = target
                    if split.memo.trimmingCharacters(in: .whitespaces).isEmpty {
                        split.memo = staged.memo.isEmpty
                            ? (staged.payee.isEmpty ? staged.memo : staged.payee)
                            : staged.memo
                    }
                    if !staged.reference.isEmpty {
                        split.kvp["online_id"] = .string(staged.reference)
                    }
                }
                for (split, reference) in referenced {
                    split.kvp["online_id"] = .string(reference)
                }
            }
        }
        return imported
    }

    /// The book's existing `Imbalance-<CUR>` account matching the target's
    /// currency, for parking rows nothing categorised. Lookup only — import
    /// never creates accounts.
    func imbalanceFallback(for target: Account) -> Account? {
        book?.accounts.first {
            $0.isImbalanceOrOrphan && !$0.isPlaceholder && $0.commodity == target.commodity
        }
    }
}

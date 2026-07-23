//
//  AppModel+Intelligence.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensInterchange
import FinvestLensIntelligence
import FinvestLensReports

/// Apple Intelligence features (`FR-AI-01…06`). Everything here follows the
/// same contract: extraction and suggestion run on the on-device model
/// (nothing leaves the Mac), results are *proposals* the user reviews in UI,
/// and only deterministic code mutates the book.
@MainActor
extension AppModel {

    // MARK: Availability

    /// Live availability of the on-device model (device, OS, setting).
    public var intelligenceStatus: IntelligenceAvailability {
        IntelligenceAvailability.current()
    }

    public var isIntelligenceAvailable: Bool {
        intelligenceStatus.isAvailable
    }

    /// Why intelligence features are disabled, for menu help/tooltips.
    public var intelligenceUnavailableReason: String? {
        if case .unavailable(let reason) = intelligenceStatus { return reason }
        return nil
    }

    private func requireIntelligence() throws {
        if case .unavailable(let reason) = intelligenceStatus {
            throw IntelligenceError.unavailable(reason)
        }
    }

    // MARK: Category candidates

    /// Income + expense accounts offered to the model as categorisation
    /// targets. Value types only — Engine classes never cross to the model.
    func categoryCandidates(includeIncome: Bool = true) -> [CategoryCandidate] {
        postableAccounts
            .filter { $0.typeName == "Expense" || (includeIncome && $0.typeName == "Income") }
            .map { CategoryCandidate(id: $0.id, fullName: $0.fullName) }
    }

    // MARK: FR-AI-01 — PDF statement import

    /// Extracts staged transactions from a PDF bank/card statement using the
    /// on-device model. The result feeds the normal import review flow.
    public func extractStatementPDF(
        _ data: Data,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [StagedTransaction] {
        try requireIntelligence()
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw IntelligenceError.unavailable("Apple Intelligence requires macOS 26 or iOS 26.")
        }
        let pages = try await Task.detached { try await DocumentText.extractPages(from: data) }.value
        return try await StatementExtractor.extract(pages: pages, onProgress: onProgress)
    }

    /// Marks the existing register splits matched by duplicate import rows as
    /// cleared — importing a statement doubles as a light reconciliation pass.
    ///
    /// - Returns: how many splits were newly marked cleared.
    @discardableResult
    public func reconcileMatchedDuplicates(_ results: [MatchResult]) -> Int {
        guard let book else { return 0 }
        let matches = results.compactMap { result -> (split: Split, date: Date)? in
            guard result.isDuplicate,
                  let splitID = result.matchedSplitID,
                  let split = book.split(with: splitID),
                  split.reconcileState == .notReconciled
            else { return nil }
            return (split, result.staged.date)
        }
        let updated = matches.count
        if updated > 0 {
            let touched = Set(matches.compactMap { $0.split.transaction?.guid })
            editing(Array(touched), named: "Clear Matched Splits") {
                for (split, date) in matches {
                    split.reconcileState = .cleared
                    split.reconcileDate = date
                }
            }
        }
        return updated
    }

    // MARK: FR-AI-02 — Auto-categorisation

    /// Suggests destination accounts for staged import rows that still lack
    /// one. Keyed by `StagedTransaction.id`, ready to merge into the import
    /// view's assignments.
    public func suggestCategories(for results: [MatchResult]) async throws -> [UUID: GncGUID] {
        try requireIntelligence()
        guard #available(macOS 26.0, iOS 26.0, *) else { return [:] }
        let items = results
            .filter { !$0.isDuplicate }
            .map {
                CategorizationItem(id: $0.staged.id,
                                   payee: $0.staged.payee.isEmpty ? $0.staged.memo : $0.staged.payee,
                                   memo: $0.staged.memo,
                                   amount: $0.staged.amount)
            }
        return try await TransactionCategorizer.suggest(items: items, candidates: categoryCandidates())
    }

    /// A posted transaction whose counter-leg sits in an `Imbalance-*` /
    /// `Orphan-*` account — i.e. imported or scrubbed without a real category.
    public struct UncategorizedItem: Identifiable, Sendable {
        public let id: UUID
        public let splitID: GncGUID
        public let transactionID: GncGUID
        public let date: Date
        public let transactionDescription: String
        /// Value of the uncategorised leg, in transaction currency.
        public let amount: Decimal
        public let currencyCode: String
    }

    /// All splits currently posted to Imbalance/Orphan accounts. When
    /// `transactions` is supplied, only splits belonging to those transactions
    /// are returned — used to scope Auto-Categorise to the register selection.
    public func uncategorizedItems(limitedTo transactions: Set<GncGUID>? = nil) -> [UncategorizedItem] {
        guard let book else { return [] }
        let holders = book.accounts.filter(\.isImbalanceOrOrphan)
        return holders.flatMap { holder in
            book.splits(for: holder).compactMap { split -> UncategorizedItem? in
                guard let transaction = split.transaction else { return nil }
                if let transactions, !transactions.contains(transaction.guid) { return nil }
                return UncategorizedItem(
                    id: UUID(),
                    splitID: split.guid,
                    transactionID: transaction.guid,
                    date: transaction.datePosted,
                    transactionDescription: transaction.transactionDescription,
                    amount: split.value,
                    currencyCode: transaction.currency.mnemonic
                )
            }
        }
        .sorted { $0.date < $1.date }
    }

    /// Model-suggested categories for uncategorised items, keyed by item ID.
    public func suggestCategoriesForUncategorized(
        _ items: [UncategorizedItem]
    ) async throws -> [UUID: GncGUID] {
        try requireIntelligence()
        guard #available(macOS 26.0, iOS 26.0, *) else { return [:] }
        let categorizables = items.map {
            // The counter-leg of spending is positive in the imbalance account,
            // so flip the sign to present the account holder's perspective.
            CategorizationItem(id: $0.id, payee: $0.transactionDescription, amount: -$0.amount)
        }
        return try await TransactionCategorizer.suggest(items: categorizables,
                                                        candidates: categoryCandidates())
    }

    /// Moves uncategorised splits onto their chosen accounts (one undoable
    /// change). Keys are split GUIDs; values the destination account.
    @discardableResult
    public func applyCategoryAssignments(_ assignments: [GncGUID: GncGUID]) -> Int {
        guard let book else { return 0 }
        let moves = assignments.compactMap { splitID, accountID -> (split: Split, account: Account)? in
            guard let split = book.split(with: splitID),
                  let account = book.account(with: accountID)
            else { return nil }
            return (split, account)
        }
        let applied = moves.count
        if applied > 0 {
            let touched = Set(moves.compactMap { $0.split.transaction?.guid })
            editing(Array(touched), named: "Categorise Transactions") {
                for (split, account) in moves { split.account = account }
            }
        }
        return applied
    }

    // MARK: Categorise from attachment

    /// What an attachment read proposes for its transaction: a category, and —
    /// when it differs from the current description — a friendly payee to
    /// rename to (the raw narrative moves to the money-leg memo on apply, the
    /// smart categoriser's convention).
    public struct AttachmentCategorySuggestion: Sendable {
        public let accountID: GncGUID
        public let accountName: String
        public let friendlyDescription: String?
        public let currencyCode: String
        /// Invoice line items (two or more) to split across instead of the
        /// single category — one leg per item, already scaled so they sum to
        /// exactly what the replaced leg must carry.
        public let lines: [SplitLine]?

        public struct SplitLine: Sendable, Identifiable {
            public let id = UUID()
            public let accountID: GncGUID
            public let accountName: String
            public let memo: String
            public let value: Decimal
        }
    }

    /// The leg an attachment suggestion may replace: the uncategorised one, or
    /// the counter leg of a simple two-leg transaction. `nil` for multi-split
    /// fully-categorised transactions (inspector territory).
    private func attachmentTargetSplit(in txn: Transaction) -> Split? {
        if let imbalance = txn.splits.first(where: { $0.account?.isImbalanceOrOrphan ?? false }) {
            return imbalance
        }
        guard txn.splits.count == 2,
              txn.splits.allSatisfy({ $0.account?.commodity == txn.currency }),
              let money = txn.splits.first(where: { Self.isMoneyLeg($0) })
        else { return nil }
        return txn.splits.first { $0 !== money }
    }

    private static let attachmentMoneyTypes: Set<AccountType> = [
        .bank, .cash, .credit, .asset, .liability, .receivable, .payable,
    ]

    private static func isMoneyLeg(_ split: Split) -> Bool {
        split.account.map { attachmentMoneyTypes.contains($0.type) && !$0.isImbalanceOrOrphan } ?? false
    }

    // MARK: Bulk attachment matching

    /// One picked file's journey: the transaction it matched (by amount and
    /// date, across every account), and what applying would do.
    public struct AttachmentMatch: Identifiable, Sendable {
        public let id = UUID()
        public let url: URL
        public var fileName: String { url.lastPathComponent }
        public var transactionID: GncGUID?
        public var transactionSummary: String = ""
        public var suggestion: AttachmentCategorySuggestion?
        /// Why there is nothing to apply, when there isn't.
        public var note: String?
    }

    /// Matches a batch of picked files to transactions: each file is OCR'd, its
    /// amount and date read (dividend statement or invoice), and the book
    /// searched — any account — for an unlinked transaction with a money leg of
    /// exactly that amount within ±14 days (closest date wins). Matched files
    /// also get the full attachment categorisation suggestion. Nothing is
    /// linked or applied here — the review sheet does that.
    public func matchAttachments(
        urls: [URL],
        onProgress: (@MainActor (Int, Int) -> Void)? = nil
    ) async -> [AttachmentMatch] {
        guard #available(macOS 26.0, iOS 26.0, *), isIntelligenceAvailable else {
            let note = intelligenceUnavailableReason ?? "Apple Intelligence is unavailable."
            return urls.map { var match = AttachmentMatch(url: $0); match.note = note; return match }
        }
        let candidates = categoryCandidates()

        // Stage 1 — parse in parallel (a few at a time): OCR plus ONE
        // extraction per file, with the invoice pass carrying its per-line
        // categorisation. The sequential version re-parsed every document for
        // the suggestion, which at 3–4 model calls per file made a 51-file
        // batch take the better part of an hour.
        var parsed = [ParsedAttachment?](repeating: nil, count: urls.count)
        var completed = 0
        onProgress?(0, urls.count)
        await withTaskGroup(of: (Int, ParsedAttachment).self) { group in
            var next = 0
            func addNext() {
                guard next < urls.count else { return }
                let index = next
                let url = urls[index]
                next += 1
                group.addTask { (index, await Self.parseAttachment(url: url, candidates: candidates)) }
            }
            for _ in 0..<min(Self.physicalCPUCount, urls.count) { addNext() }
            for await (index, result) in group {
                parsed[index] = result
                completed += 1
                onProgress?(completed, urls.count)
                if Task.isCancelled { group.cancelAll() } else { addNext() }
            }
        }

        // Stage 2 — match and build suggestions: book work only, no model calls.
        var results: [AttachmentMatch] = []
        for (index, url) in urls.enumerated() {
            if Task.isCancelled { break }
            var match = AttachmentMatch(url: url)
            defer { results.append(match) }
            guard let doc = parsed[index] else { match.note = "Cancelled."; continue }
            if let note = doc.note { match.note = note; continue }

            var matched: Transaction?
            if let amount = doc.amount {
                matched = findTransaction(amount: amount, near: doc.date)
                if matched == nil {
                    match.note = "No unlinked transaction matches \(amount) around that date."
                }
            } else if !doc.fallbackAmounts.isEmpty {
                // The model couldn't name a total — try every money-looking
                // amount the OCR found (largest first) against the book.
                for amount in doc.fallbackAmounts {
                    if let hit = findTransaction(amount: amount, near: doc.fallbackDate) {
                        matched = hit
                        break
                    }
                }
                if matched == nil {
                    let tried = doc.fallbackAmounts.map { "\($0)" }.joined(separator: ", ")
                    match.note = "Couldn’t read a total; none of the amounts found (\(tried)) match an unlinked transaction."
                }
            } else {
                match.note = "Couldn’t read an amount from the document."
            }
            guard let txn = matched else { continue }
            match.transactionID = txn.guid
            match.transactionSummary = transactionSummary(txn)
            match.note = nil
            match.suggestion = suggestion(for: txn, from: doc)
        }
        return results
    }

    /// Physical performance cores — the parse pipeline's width. OCR and the
    /// on-device model are compute-bound, so logical cores oversubscribe.
    nonisolated private static var physicalCPUCount: Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.physicalcpu", &count, &size, nil, 0) == 0, count > 0 {
            return Int(count)
        }
        return max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    }

    /// One file, fully parsed: the OCR text, and whichever extraction fit —
    /// a dividend statement or an invoice (with per-line categories).
    struct ParsedAttachment: Sendable {
        var note: String?
        var dividend: DividendStatementDetails?
        var invoice: InvoiceAnalysis?
        /// Money-looking amounts scanned from the OCR text (largest first) —
        /// the match fallback when the model can't name a total.
        var fallbackAmounts: [Decimal] = []
        var fallbackDate: Date?

        var amount: Decimal? {
            if let dividend, dividend.netPayment > 0 { return dividend.netPayment }
            if let invoice, invoice.total > 0 { return invoice.total }
            return nil
        }
        var date: Date? { dividend?.paymentDate ?? invoice?.date }
    }

    @available(macOS 26.0, iOS 26.0, *)
    nonisolated private static func parseAttachment(
        url: URL, candidates: [CategoryCandidate]
    ) async -> ParsedAttachment {
        var doc = ParsedAttachment()
        guard await waitForLocalFile(url) else {
            doc.note = cloudPlaceholderExists(url)
                ? "Still downloading from the cloud — try again shortly."
                : "Couldn’t read the file."
            return doc
        }
        let text: String
        do {
            text = try await DocumentText.extractText(from: url)
        } catch {
            doc.note = "Couldn’t read the file."
            return doc
        }
        let lower = text.lowercased()
        if lower.contains("dividend"), lower.contains("frank") || lower.contains("imputation") {
            doc.dividend = try? await DividendExtractor.extract(text: String(text.prefix(4000)))
        }
        if doc.dividend == nil || (doc.dividend?.netPayment ?? 0) <= 0 {
            doc.invoice = try? await InvoiceAnalyzer.analyze(
                text: String(text.prefix(6000)), candidates: candidates)
        }
        if doc.amount == nil {
            doc.fallbackAmounts = Self.amountCandidates(in: text)
            doc.fallbackDate = Self.firstDate(in: text)
        }
        return doc
    }

    /// Every distinct money-looking amount in the text (`1,234.56`), largest
    /// first, capped at eight — totals outrank line items.
    nonisolated static func amountCandidates(in text: String) -> [Decimal] {
        let pattern = #"(?<![\d.])\d{1,3}(?:,\d{3})*\.\d{2}(?!\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var seen = Set<Decimal>()
        var amounts: [Decimal] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let cleaned = text[range].replacingOccurrences(of: ",", with: "")
            if let amount = Decimal(string: cleaned), amount > 0, seen.insert(amount).inserted {
                amounts.append(amount)
            }
        }
        return Array(amounts.sorted(by: >).prefix(8))
    }

    nonisolated static func firstDate(in text: String) -> Date? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        return detector?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.date
    }

    /// The suggestion for a matched file, built from its one parse — dividend
    /// franking split, per-item invoice split, or the invoice's dominant
    /// category — with the vendor / ticker as the friendly rename.
    @available(macOS 26.0, iOS 26.0, *)
    private func suggestion(for txn: Transaction,
                            from doc: ParsedAttachment) -> AttachmentCategorySuggestion? {
        if let details = doc.dividend, let lines = dividendSplitLines(for: txn, details: details) {
            let ticker = details.ticker.trimmingCharacters(in: .whitespaces).uppercased()
            let friendly = ticker.isEmpty ? nil : "\(ticker) dividend"
            return AttachmentCategorySuggestion(
                accountID: lines[0].accountID,
                accountName: lines[0].accountName,
                friendlyDescription: friendly == txn.transactionDescription ? nil : friendly,
                currencyCode: txn.currency.mnemonic,
                lines: lines)
        }
        guard let book, let invoice = doc.invoice else { return nil }
        // The dominant per-line category anchors both the single suggestion and
        // any lines the model couldn't place.
        let counted = Dictionary(grouping: invoice.lineItems.compactMap(\.suggestedCategoryID),
                                 by: { $0 }).mapValues(\.count)
        guard let dominant = counted.max(by: { $0.value < $1.value })?.key,
              let account = book.account(with: dominant) else { return nil }
        let vendor = invoice.vendor.trimmingCharacters(in: .whitespaces)
        let friendly = (vendor.isEmpty || vendor == txn.transactionDescription) ? nil : vendor
        return AttachmentCategorySuggestion(
            accountID: dominant,
            accountName: account.fullName,
            friendlyDescription: friendly,
            currencyCode: txn.currency.mnemonic,
            lines: invoiceLines(from: invoice, for: txn, fallbackAccountID: dominant))
    }

    /// The best unlinked transaction for an amount: a money leg of exactly that
    /// magnitude, posted within ±14 days of the document date (closest wins;
    /// no document date accepts any).
    private func findTransaction(amount: Decimal, near date: Date?) -> Transaction? {
        guard let book else { return nil }
        let calendar = Calendar.current
        var best: (txn: Transaction, days: Int)?
        for txn in book.transactions {
            guard txn.documentLink == nil else { continue }
            guard txn.splits.contains(where: { Self.isMoneyLeg($0) && abs($0.value) == amount })
            else { continue }
            let days: Int
            if let date {
                days = abs(calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                                   to: calendar.startOfDay(for: txn.datePosted)).day ?? 999)
                guard days <= 14 else { continue }
            } else {
                days = 0
            }
            if best == nil || days < best!.days { best = (txn, days) }
        }
        return best?.txn
    }

    private func transactionSummary(_ txn: Transaction) -> String {
        let account = txn.splits.first(where: Self.isMoneyLeg)?.account?.name ?? "—"
        let amount = txn.splits.first(where: Self.isMoneyLeg)?.value ?? 0
        return "\(AppDateFormat.current.short(txn.datePosted)) · \(txn.transactionDescription) · \(account) · \(AmountFormat.string(amount, code: txn.currency.mnemonic))"
    }

    /// Reads the transaction's linked attachment (PDF or image — OCR as
    /// needed) and asks the on-device model for the best category from the
    /// book's chart *and* a friendly payee. Works whether or not the
    /// transaction is already categorised. Returns `nil` when the model has no
    /// confident answer.
    public func suggestCategoryFromAttachment(
        for transactionID: GncGUID
    ) async throws -> AttachmentCategorySuggestion? {
        try requireIntelligence()
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw IntelligenceError.unavailable("Apple Intelligence requires macOS 26 or iOS 26.")
        }
        guard let book, let txn = book.transaction(with: transactionID) else { return nil }
        guard let url = linkedDocumentURL(for: transactionID) else {
            throw IntelligenceError.unavailable("The transaction has no readable attachment.")
        }
        guard await ensureLocalFile(url) else {
            throw IntelligenceError.unavailable(
                Self.cloudPlaceholderExists(url)
                    ? "The attachment is still downloading from the cloud — try again shortly."
                    : "The attachment file was not found.")
        }
        let text = try await Task.detached { try await DocumentText.extractText(from: url) }.value
        return try await attachmentSuggestion(for: transactionID, text: text)
    }

    /// The suggestion core, over already-extracted document text — shared by
    /// the sidebar (which resolves the transaction's link) and the bulk
    /// match-attachments flow (which brings its own files).
    @available(macOS 26.0, iOS 26.0, *)
    func attachmentSuggestion(
        for transactionID: GncGUID, text: String
    ) async throws -> AttachmentCategorySuggestion? {
        guard let book, let txn = book.transaction(with: transactionID) else { return nil }
        // The uncategorised leg gives the model the amount's sign; else any leg.
        let imbalance = txn.splits.first { $0.account?.isImbalanceOrOrphan ?? false }
        let amount = -(imbalance?.value ?? txn.splits.first?.value ?? 0)
        let candidates = categoryCandidates()

        // A dividend statement gets the book's own franking structure, modelled
        // on how existing dividends are recorded — checked first, because a
        // dividend also reads like a small invoice.
        let lower = text.lowercased()
        if lower.contains("dividend"),
           lower.contains("frank") || lower.contains("imputation"),
           let details = try? await DividendExtractor.extract(text: String(text.prefix(4000))),
           let dividend = dividendSplitLines(for: txn, details: details) {
            let ticker = details.ticker.trimmingCharacters(in: .whitespaces).uppercased()
            let friendly = ticker.isEmpty ? nil : "\(ticker) dividend"
            return AttachmentCategorySuggestion(
                accountID: dividend[0].accountID,
                accountName: dividend[0].accountName,
                friendlyDescription: friendly == txn.transactionDescription ? nil : friendly,
                currencyCode: txn.currency.mnemonic,
                lines: dividend)
        }

        guard let insight = try await AttachmentInsight.analyze(
            documentText: String(text.prefix(1600)),
            currentDescription: txn.transactionDescription,
            amount: amount,
            candidates: candidates)
        else { return nil }
        guard let account = book.account(with: insight.accountID) else { return nil }
        let friendly = insight.friendlyDescription
        return AttachmentCategorySuggestion(
            accountID: insight.accountID,
            accountName: account.fullName,
            friendlyDescription: (friendly.isEmpty || friendly == txn.transactionDescription)
                ? nil : friendly,
            currencyCode: txn.currency.mnemonic,
            lines: await invoiceSplitLines(for: txn, text: text,
                                           fallbackAccountID: insight.accountID,
                                           candidates: candidates))
    }

    /// The franking split for a dividend statement, built the way the book's
    /// existing dividends are recorded (the CDIA guide): per-security income
    /// legs (Dividends ▸ TICKER ▸ Franked / Unfranked / Imputation Credit), the
    /// gross-up offset to the imputation expense account (income + expense net
    /// to zero, so cash is untouched), and the zero-value stock link leg.
    /// `nil` — falling back to the generic paths — when the statement's cash
    /// doesn't match the transaction, or the book has no per-security accounts
    /// for this ticker (accounts are never invented here).
    @available(macOS 26.0, iOS 26.0, *)
    private func dividendSplitLines(
        for txn: Transaction,
        details: DividendStatementDetails
    ) -> [AttachmentCategorySuggestion.SplitLine]? {
        guard let book, let target = attachmentTargetSplit(in: txn) else { return nil }
        let ticker = details.ticker.trimmingCharacters(in: .whitespaces).uppercased()
        guard !ticker.isEmpty, details.netPayment > 0 else { return nil }

        // The statement's cash must be this transaction's cash.
        let expected = -target.value
        guard expected > 0, abs(expected - details.netPayment) <= Decimal(string: "0.05")! else { return nil }

        // The per-security income group, as existing dividends use it.
        func lowername(_ account: Account) -> String { account.name.lowercased() }
        var frankedAccount: Account?
        var unfrankedAccount: Account?
        var creditsAccount: Account?
        for account in book.accounts where account.type == .income {
            guard lowername(account).contains("franked"), !lowername(account).contains("unfranked"),
                  let parent = account.parent,
                  parent.name.caseInsensitiveCompare(ticker) == .orderedSame else { continue }
            frankedAccount = account
            unfrankedAccount = parent.children.first {
                $0.type == .income && lowername($0).contains("unfranked")
            }
            creditsAccount = parent.children.first {
                $0.type == .income
                    && (lowername($0).contains("imputation") || lowername($0).contains("franking"))
            }
            break
        }
        guard let frankedAccount else { return nil }

        let currency = txn.currency
        let unfranked = currency.round(details.unfrankedAmount)
        let credits = currency.round(details.frankingCredits)
        // Cash must balance exactly — extraction rounding lands on the franked leg.
        let franked = expected - unfranked
        guard franked > 0, unfranked >= 0, credits >= 0 else { return nil }
        if unfranked > 0, unfrankedAccount == nil { return nil }

        var lines: [AttachmentCategorySuggestion.SplitLine] = [
            .init(accountID: frankedAccount.guid, accountName: frankedAccount.fullName,
                  memo: "", value: -franked),
        ]
        if unfranked > 0, let unfrankedAccount {
            lines.append(.init(accountID: unfrankedAccount.guid,
                               accountName: unfrankedAccount.fullName,
                               memo: "", value: -unfranked))
        }
        // The gross-up: imputation-credit income offset by the imputation
        // expense — nets to zero, mirroring the book's existing dividends.
        if credits > 0, let creditsAccount,
           let offset = book.accounts.first(where: { account in
               account.type == .expense
                   && (lowername(account).contains("imputation") || lowername(account).contains("franking"))
           }) {
            lines.append(.init(accountID: creditsAccount.guid,
                               accountName: creditsAccount.fullName,
                               memo: "", value: -credits))
            lines.append(.init(accountID: offset.guid, accountName: offset.fullName,
                               memo: "", value: credits))
        }
        // The zero-value stock link leg existing dividends carry.
        if let stock = book.accounts.first(where: { account in
            (account.type == .stock || account.type == .mutualFund)
                && (account.name.caseInsensitiveCompare(ticker) == .orderedSame
                    || account.commodity.mnemonic.uppercased() == ticker
                    || account.commodity.mnemonic.uppercased().hasPrefix(ticker + "."))
        }) {
            lines.append(.init(accountID: stock.guid, accountName: stock.fullName,
                               memo: "", value: 0))
        }
        return lines.count >= 2 ? lines : nil
    }

    /// When the document is an invoice with several line items, the per-item
    /// legs that should replace the single category: each item's amount scaled
    /// so the legs sum to exactly what the replaced leg must carry (an invoice
    /// often quotes GST or shipping apart from its lines), with the rounding
    /// residual absorbed by the largest. `nil` when the document doesn't read
    /// as a multi-item invoice, the amounts are nowhere near the charge, or
    /// the transaction has no replaceable leg.
    @available(macOS 26.0, iOS 26.0, *)
    private func invoiceSplitLines(
        for txn: Transaction, text: String,
        fallbackAccountID: GncGUID,
        candidates: [CategoryCandidate]
    ) async -> [AttachmentCategorySuggestion.SplitLine]? {
        guard let analysis = try? await InvoiceAnalyzer.analyze(
            text: String(text.prefix(4000)), candidates: candidates) else { return nil }
        return invoiceLines(from: analysis, for: txn, fallbackAccountID: fallbackAccountID)
    }

    /// Builds the per-item legs from an already-run invoice analysis — pure
    /// book work, shared by the sidebar and bulk paths.
    private func invoiceLines(
        from analysis: InvoiceAnalysis,
        for txn: Transaction,
        fallbackAccountID: GncGUID
    ) -> [AttachmentCategorySuggestion.SplitLine]? {
        guard let book, let target = attachmentTargetSplit(in: txn),
              analysis.lineItems.count >= 2 else { return nil }

        let magnitudes = analysis.lineItems.map { max($0.amount, 0) }
        let total = magnitudes.reduce(Decimal(0), +)
        let targetValue = target.value
        guard total > 0, targetValue != 0 else { return nil }
        // The lines must be in the same ballpark as the charge — a factor-of-two
        // mismatch means the OCR missed half the invoice, and splitting by it
        // would fabricate numbers.
        let ratio = abs((targetValue as NSDecimalNumber).doubleValue)
            / (total as NSDecimalNumber).doubleValue
        guard ratio > 0.66, ratio < 1.5 else { return nil }

        let currency = txn.currency
        let scale = targetValue / total
        var lines: [AttachmentCategorySuggestion.SplitLine] = []
        for (item, magnitude) in zip(analysis.lineItems, magnitudes) where magnitude > 0 {
            let accountID = item.suggestedCategoryID ?? fallbackAccountID
            guard let account = book.account(with: accountID),
                  account.commodity == currency else { return nil }
            lines.append(AttachmentCategorySuggestion.SplitLine(
                accountID: accountID, accountName: account.fullName,
                memo: item.itemDescription,
                value: currency.round(magnitude * scale)))
        }
        guard lines.count >= 2 else { return nil }
        // Exact balance: the legs must sum to precisely the replaced leg's value.
        let residual = targetValue - lines.reduce(Decimal(0)) { $0 + $1.value }
        if residual != 0,
           let biggest = lines.indices.max(by: { abs(lines[$0].value) < abs(lines[$1].value) }) {
            let line = lines[biggest]
            lines[biggest] = AttachmentCategorySuggestion.SplitLine(
                accountID: line.accountID, accountName: line.accountName,
                memo: line.memo, value: line.value + residual)
        }
        return lines
    }

    /// Attachment-driven suggestions for uncategorised items — the opt-in
    /// "Read Attachments" pass in Auto-Categorise. Each item whose transaction
    /// carries a readable linked document is OCR'd, and the text handed to the
    /// on-device model as context beside the description and amount. Keyed by
    /// item ID; items without attachments or a confident answer are absent.
    public func suggestCategoriesFromAttachments(
        _ items: [UncategorizedItem],
        onProgress: (@MainActor (Int, Int) -> Void)? = nil
    ) async throws -> [UUID: GncGUID] {
        try requireIntelligence()
        guard #available(macOS 26.0, iOS 26.0, *) else { return [:] }
        let withDocs = items.filter { item in
            guard let url = linkedDocumentURL(for: item.transactionID) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
        guard !withDocs.isEmpty else { return [:] }

        var categorizables: [CategorizationItem] = []
        for (index, item) in withDocs.enumerated() {
            onProgress?(index, withDocs.count)
            guard let url = linkedDocumentURL(for: item.transactionID) else { continue }
            let text: String
            do {
                text = try await Task.detached { try await DocumentText.extractText(from: url) }.value
            } catch {
                continue   // unreadable attachment — the item just isn't suggested
            }
            categorizables.append(CategorizationItem(
                id: item.id,
                payee: item.transactionDescription,
                memo: String(text.prefix(1200)),
                amount: -item.amount))
        }
        onProgress?(withDocs.count, withDocs.count)
        guard !categorizables.isEmpty else { return [:] }
        return try await TransactionCategorizer.suggest(items: categorizables,
                                                        candidates: categoryCandidates())
    }

    /// Applies an attachment-derived suggestion as ONE undoable edit — on
    /// uncategorised *and* already-categorised transactions:
    /// - category: moves the uncategorised leg when there is one, else
    ///   re-targets the counter leg of a simple two-leg transaction;
    /// - friendly rename: the description becomes the friendly payee and the
    ///   raw bank narrative moves to the money-leg memo (only when that memo is
    ///   empty) — the smart categoriser's convention.
    /// Multi-split fully-categorised transactions are refused (edit those in
    /// the inspector, where every leg is visible).
    @discardableResult
    public func applyAttachmentSuggestion(_ suggestion: AttachmentCategorySuggestion,
                                          to transactionID: GncGUID) -> Bool {
        guard let book, let txn = book.transaction(with: transactionID),
              let account = book.account(with: suggestion.accountID),
              account.commodity == txn.currency,
              let target = attachmentTargetSplit(in: txn) else { return false }

        // An invoice split only applies when its legs still sum to exactly what
        // the replaced leg carries — if the transaction changed since the
        // suggestion was made, refuse rather than unbalance.
        let lines = suggestion.lines
        if let lines {
            guard lines.reduce(Decimal(0), { $0 + $1.value }) == target.value,
                  lines.allSatisfy({ line in
                      line.value == 0   // the zero-value stock link leg
                          || book.account(with: line.accountID)?.commodity == txn.currency
                  })
            else { return false }
        }

        editing([transactionID], named: "Categorise from Attachment") {
            if let friendly = suggestion.friendlyDescription?.trimmingCharacters(in: .whitespaces),
               !friendly.isEmpty, friendly != txn.transactionDescription {
                let narrative = txn.transactionDescription
                for split in txn.splits where Self.isMoneyLeg(split) && split !== target {
                    if split.memo.trimmingCharacters(in: .whitespaces).isEmpty {
                        split.memo = narrative
                    }
                }
                txn.transactionDescription = friendly
            }
            if let lines {
                // One leg per invoice item, replacing the single target leg.
                txn.removeSplit(target)
                for line in lines {
                    guard let lineAccount = book.account(with: line.accountID) else { continue }
                    txn.addSplit(account: lineAccount, value: line.value, memo: line.memo)
                }
            } else {
                target.account = account
                target.quantity = target.value   // same-currency by the guard above
            }
        }
        return true
    }

    // MARK: FR-AI-03 — Invoice splitting

    /// Analyses an invoice PDF into line items with expense-account
    /// suggestions, for splitting a single card charge across categories.
    public func analyzeInvoicePDF(_ data: Data) async throws -> InvoiceAnalysis {
        try requireIntelligence()
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw IntelligenceError.unavailable("Apple Intelligence requires macOS 26 or iOS 26.")
        }
        let text = try await Task.detached { try await DocumentText.extractText(from: data) }.value
        return try await InvoiceAnalyzer.analyze(text: text,
                                                 candidates: categoryCandidates(includeIncome: false))
    }

    // MARK: FR-AI-04 — Dividend statements

    /// Reads a dividend statement PDF (franked/unfranked/franking credits).
    public func extractDividendStatement(_ data: Data) async throws -> DividendStatementDetails {
        try requireIntelligence()
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw IntelligenceError.unavailable("Apple Intelligence requires macOS 26 or iOS 26.")
        }
        let text = try await Task.detached { try await DocumentText.extractText(from: data) }.value
        return try await DividendExtractor.extract(text: text)
    }

    /// Books a reviewed dividend: cash to the chosen account, income split
    /// into franked/unfranked components, and — when enabled — the franking
    /// credit gross-up (income + ATO receivable, which nets to zero so the
    /// cash amount is untouched).
    ///
    /// Standard accounts are created on demand under `Income:Dividends` and
    /// `Assets:Franking Credits Receivable`.
    @discardableResult
    public func recordDividend(
        _ details: DividendStatementDetails,
        cashAccountID: GncGUID,
        recordFrankingCredits: Bool = true
    ) throws -> GncGUID {
        guard let book, let cash = book.account(with: cashAccountID) else {
            throw TransactionEntryError.unknownAccount
        }
        var splits = [SplitInput(accountID: cashAccountID, value: details.netPayment)]
        if details.frankedAmount != 0 {
            let account = ensureAccount(path: ["Income", "Dividends", "Franked Dividends"], type: .income)
            splits.append(SplitInput(accountID: account?.guid, value: -details.frankedAmount,
                                     memo: details.ticker))
        }
        if details.unfrankedAmount != 0 {
            let account = ensureAccount(path: ["Income", "Dividends", "Unfranked Dividends"], type: .income)
            splits.append(SplitInput(accountID: account?.guid, value: -details.unfrankedAmount,
                                     memo: details.ticker))
        }
        if recordFrankingCredits && details.frankingCredits != 0 {
            let income = ensureAccount(path: ["Income", "Dividends", "Franking Credits"], type: .income)
            let receivable = ensureAccount(path: ["Assets", "Franking Credits Receivable"], type: .asset)
            splits.append(SplitInput(accountID: income?.guid, value: -details.frankingCredits,
                                     memo: details.ticker))
            splits.append(SplitInput(accountID: receivable?.guid, value: details.frankingCredits,
                                     memo: details.ticker))
        }
        let name = details.securityName.isEmpty ? details.ticker : details.securityName
        return try addTransaction(
            date: details.paymentDate ?? Date(),
            description: "Dividend — \(name)",
            currency: cash.commodity,
            splits: splits,
            tags: ["dividend"]
        )
    }

    /// Finds or creates the account at `path` (from the root), giving new
    /// accounts the report currency.
    func ensureAccount(path: [String], type: AccountType) -> Account? {
        guard let book, !path.isEmpty else { return nil }
        var parent = book.rootAccount
        for name in path {
            if let existing = parent.children.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) {
                parent = existing
            } else {
                let account = Account(name: name, type: type, commodity: reportCurrency)
                book.addAccount(account, under: parent)
                parent = account
            }
        }
        return parent
    }

    // MARK: FR-AI-05 — Auto-budgeting

    /// Per-category monthly spending stats over the last `months` complete
    /// months — the deterministic input the budget advisor reasons over.
    public func spendingHistory(months: Int = 6) -> [SpendingHistory] {
        guard let book else { return [] }
        let windows = monthWindows(back: months)
        guard !windows.isEmpty else { return [] }
        return book.accounts.compactMap { account -> SpendingHistory? in
            guard account.type == .expense, !account.isPlaceholder else { return nil }
            let actuals = windows.map {
                FinancialReports.periodActual(of: account, in: book, from: $0.0, to: $0.1)
            }
            let average = reportCurrency.round(
                actuals.reduce(0, +) / Decimal(actuals.count)
            )
            guard average > 0 else { return nil }
            return SpendingHistory(
                categoryID: account.guid,
                fullName: account.fullName,
                monthlyAverage: average,
                monthlyMinimum: actuals.min() ?? 0,
                monthlyMaximum: actuals.max() ?? 0
            )
        }
        .sorted { $0.monthlyAverage > $1.monthlyAverage }
    }

    /// Average monthly income over the last `months` complete months.
    public func monthlyIncomeAverage(months: Int = 6) -> Decimal {
        guard let book else { return 0 }
        let windows = monthWindows(back: months)
        guard !windows.isEmpty else { return 0 }
        let total = windows.reduce(Decimal(0)) { sum, window in
            sum + book.accounts
                .filter { $0.type == .income && !$0.isPlaceholder }
                .reduce(Decimal(0)) {
                    $0 + FinancialReports.periodActual(of: $1, in: book, from: window.0, to: window.1)
                }
        }
        return reportCurrency.round(total / Decimal(windows.count))
    }

    /// Proposes a monthly budget from spending history via the on-device model.
    public func suggestBudget(months: Int = 6) async throws -> BudgetSuggestion {
        try requireIntelligence()
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw IntelligenceError.unavailable("Apple Intelligence requires macOS 26 or iOS 26.")
        }
        let history = spendingHistory(months: months)
        guard !history.isEmpty else {
            throw IntelligenceError.modelFailure("There is no spending history yet to budget from.")
        }
        return try await BudgetAdvisor.suggest(history: history,
                                               monthlyIncome: monthlyIncomeAverage(months: months),
                                               currencyCode: reportCurrency.mnemonic)
    }

    /// Writes accepted suggestion lines into the first budget (creating a
    /// "Monthly" budget when none exists).
    public func applyBudgetSuggestion(_ lines: [BudgetSuggestionLine]) {
        guard !lines.isEmpty else { return }
        var budget = budgets.first ?? Budget(name: "Monthly")
        for line in lines {
            budget.setAmount(line.monthlyAmount, for: line.categoryID)
        }
        if budgets.isEmpty {
            addBudget(budget)
        } else {
            updateBudget(budget)
        }
    }

    private func monthWindows(back months: Int) -> [(Date, Date)] {
        guard months > 0 else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let thisMonthStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: Date())
        ) else { return [] }
        var windows: [(Date, Date)] = []
        for back in 1...months {
            guard let start = calendar.date(byAdding: .month, value: -back, to: thisMonthStart),
                  let next = calendar.date(byAdding: .month, value: 1, to: start) else { continue }
            windows.append((start, next.addingTimeInterval(-1)))
        }
        return windows
    }

    // MARK: FR-AI-06 — Forecast outlook

    /// The deterministic facts behind the cash-flow forecast, ready to narrate.
    public func forecastFacts(months: Int = 3) -> ForecastFacts? {
        guard let book,
              let accountID = defaultForecastAccountID,
              let account = book.account(with: accountID)
        else { return nil }
        let points = cashFlowForecast(accountID: accountID, months: months)
        guard let first = points.first, let last = points.last else { return nil }
        let lowest = points.min { $0.balance < $1.balance }

        // Recent monthly net income, from the income statement.
        let windows = monthWindows(back: 3)
        var net = Decimal(0)
        if let start = windows.last?.0, let end = windows.first?.1,
           let statement = incomeStatement(from: start, to: end) {
            net = reportCurrency.round(statement.netIncome / Decimal(max(1, windows.count)))
        }

        return ForecastFacts(
            currencyCode: reportCurrency.mnemonic,
            accountName: account.name,
            horizonDays: max(1, Int(last.date.timeIntervalSince(first.date) / 86_400)),
            openingBalance: first.balance,
            closingBalance: last.balance,
            lowestBalance: lowest?.balance ?? first.balance,
            lowestBalanceDate: lowest?.date,
            upcoming: points.filter { $0.change != 0 }.map { ($0.date, $0.label, $0.change) },
            recentMonthlyNet: net
        )
    }

    /// A plain-language outlook on the cash-flow forecast.
    public func forecastInsights(months: Int = 3) async throws -> ForecastInsights {
        try requireIntelligence()
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw IntelligenceError.unavailable("Apple Intelligence requires macOS 26 or iOS 26.")
        }
        guard let facts = forecastFacts(months: months) else {
            throw IntelligenceError.modelFailure("There is no asset account to forecast yet.")
        }
        return try await ForecastNarrator.narrate(facts: facts)
    }

    /// Annual-report-style notes for a computed report (`FR-AI-06`). The
    /// figures arrive already computed; the model observes, it never
    /// calculates.
    public func reportCommentary(for facts: ReportFacts) async throws -> [String] {
        try requireIntelligence()
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw IntelligenceError.unavailable("Apple Intelligence requires macOS 26 or iOS 26.")
        }
        return try await ReportNarrator.narrate(facts: facts)
    }
}

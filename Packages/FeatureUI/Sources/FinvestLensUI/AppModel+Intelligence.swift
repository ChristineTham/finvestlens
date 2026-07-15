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
        let pages = try await Task.detached { try DocumentText.extractPages(from: data) }.value
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

    /// All splits currently posted to Imbalance/Orphan accounts.
    public func uncategorizedItems() -> [UncategorizedItem] {
        guard let book else { return [] }
        let holders = book.accounts.filter(\.isImbalanceOrOrphan)
        return holders.flatMap { holder in
            book.splits(for: holder).compactMap { split -> UncategorizedItem? in
                guard let transaction = split.transaction else { return nil }
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

    // MARK: FR-AI-03 — Invoice splitting

    /// Analyses an invoice PDF into line items with expense-account
    /// suggestions, for splitting a single card charge across categories.
    public func analyzeInvoicePDF(_ data: Data) async throws -> InvoiceAnalysis {
        try requireIntelligence()
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw IntelligenceError.unavailable("Apple Intelligence requires macOS 26 or iOS 26.")
        }
        let text = try await Task.detached { try DocumentText.extractText(from: data) }.value
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
        let text = try await Task.detached { try DocumentText.extractText(from: data) }.value
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
}

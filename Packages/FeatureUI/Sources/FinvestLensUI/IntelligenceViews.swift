//
//  IntelligenceViews.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Review sheets for Apple Intelligence features. The model proposes;
//  the user reviews and commits — nothing is posted without approval.
//

import SwiftUI
import FinvestLensEngine
import FinvestLensIntelligence

// MARK: - Auto-categorisation (FR-AI-02)

/// Finds transactions still parked in Imbalance/Orphan accounts, asks the
/// on-device model for a category each, and applies the reviewed choices.
struct AutoCategorizeSheet: View {
    @Environment(\.appDateFormat) private var dateFormat
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFontScale) private var appFontScale
    private var dateWidth: CGFloat { 96 * appFontScale }

    @State private var items: [AppModel.UncategorizedItem] = []
    @State private var assignments: [GncGUID: GncGUID] = [:]  // splitID → account
    @State private var plans: [GncGUID: AppModel.CategoryPlan] = [:]  // txnID → plan
    @State private var acceptedPlans: Set<GncGUID> = []
    @State private var scopeCount: Int?
    @State private var loaded = false
    @State private var suggesting = false
    @State private var progress: (done: Int, total: Int)?
    @State private var errorMessage: String?

    /// Uncategorised splits with no smart-match plan — the ones needing a manual
    /// or AI single-category choice.
    private var pickerItems: [AppModel.UncategorizedItem] {
        items.filter { plans[$0.transactionID] == nil }
    }

    private var planList: [AppModel.CategoryPlan] {
        plans.values.sorted { $0.date < $1.date }
    }

    private var applyCount: Int {
        acceptedPlans.count + pickerItems.filter { assignments[$0.splitID] != nil }.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if !loaded {
                    ProgressView("Looking for uncategorised transactions…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    ContentUnavailableView("Nothing to categorise", systemImage: "checkmark.seal",
                                           description: Text(emptyMessage))
                } else {
                    // A lazy List (not a Form): a book with large Imbalance /
                    // Unspecified accounts can have thousands of uncategorised
                    // splits, and a Form materialises every row's account Picker
                    // at once, overflowing SwiftUI's attribute graph and crashing.
                    List {
                        if let scopeCount {
                            Section {
                                Label("Categorising \(scopeCount) selected transaction\(scopeCount == 1 ? "" : "s").",
                                      systemImage: "line.3.horizontal.decrease.circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !plans.isEmpty {
                            Section {
                                ForEach(planList) { planRow($0) }
                            } header: {
                                Text("Matched from similar transactions")
                            } footer: {
                                Text("Learned from an existing transaction with the same description, including its split breakdown (e.g. salary or dividend components).")
                            }
                        }
                        if !pickerItems.isEmpty {
                            Section {
                                Button {
                                    suggest()
                                } label: {
                                    Label(suggesting ? suggestingLabel : "Suggest Categories",
                                          systemImage: "sparkles")
                                }
                                .disabled(suggesting || !model.isIntelligenceAvailable)
                                .help(model.intelligenceUnavailableReason
                                      ?? "Let Apple Intelligence propose a category for each transaction")
                                if let errorMessage {
                                    Text(errorMessage).scaledFont(.caption).foregroundStyle(.red)
                                }
                            }
                            Section("\(pickerItems.count) to review") {
                                ForEach(pickerItems) { item in
                                    row(item)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Auto-Categorise")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply \(applyCount)") {
                        let accepted = planList.filter { acceptedPlans.contains($0.transactionID) }
                        model.applyCategorization(plans: accepted, assignments: assignments)
                        dismiss()
                    }
                    .disabled(applyCount == 0)
                }
            }
            .task {
                let scope = model.selectedTransactionIDs
                scopeCount = scope.isEmpty ? nil : scope.count
                items = model.uncategorizedItems(limitedTo: scope.isEmpty ? nil : scope)
                plans = model.smartCategoryPlans(for: items)
                acceptedPlans = Set(plans.keys)
                loaded = true
            }
        }
        .frame(minWidth: 620, minHeight: 460)
    }

    private var emptyMessage: String {
        scopeCount == nil
            ? "Every transaction already has a category."
            : "The selected transactions already have a category."
    }

    /// A read-only summary of a learned split plan, with a checkbox to accept it.
    @ViewBuilder
    private func planRow(_ plan: AppModel.CategoryPlan) -> some View {
        let accepted = Binding(
            get: { acceptedPlans.contains(plan.transactionID) },
            set: { isOn in
                if isOn { acceptedPlans.insert(plan.transactionID) }
                else { acceptedPlans.remove(plan.transactionID) }
            })
        Toggle(isOn: accepted) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(dateFormat.short(plan.date))
                        .foregroundStyle(.secondary)
                        .frame(width: dateWidth, alignment: .leading)
                    Text(plan.displayDescription).fontWeight(.medium)
                }
                if plan.newDescription != nil {
                    Text("Renamed from “\(plan.transactionDescription)” (kept in memo)")
                        .scaledFont(.caption).foregroundStyle(.tertiary)
                }
                ForEach(plan.legs) { leg in
                    HStack {
                        Text("→ \(leg.accountName)").scaledFont(.callout)
                        Spacer()
                        Text(AmountFormat.string(leg.value, code: plan.currencyCode))
                            .scaledFont(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Matched “\(plan.templateDescription)”")
                    .scaledFont(.caption).foregroundStyle(.tertiary)
            }
        }
        #if os(macOS)
        .toggleStyle(.checkbox)
        #endif
    }

    private var suggestingLabel: String {
        if let progress { return "Suggesting… (\(progress.done)/\(progress.total))" }
        return "Suggesting…"
    }

    @ViewBuilder
    private func row(_ item: AppModel.UncategorizedItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(dateFormat.short(item.date))
                    .foregroundStyle(.secondary)
                    .frame(width: dateWidth, alignment: .leading)
                Text(item.transactionDescription)
                Spacer()
                Text(AmountFormat.string(-item.amount, code: item.currencyCode))
                    .monospacedDigit()
                    .foregroundStyle(item.amount > 0 ? .red : .primary)
            }
            Picker("Category", selection: binding(for: item.splitID)) {
                Text("— keep uncategorised —").tag(GncGUID?.none)
                ForEach(model.postableAccounts) { node in
                    Text(node.fullName).tag(GncGUID?.some(node.id))
                }
            }
            .labelsHidden()
        }
    }

    private func binding(for splitID: GncGUID) -> Binding<GncGUID?> {
        Binding(
            get: { assignments[splitID] },
            set: { assignments[splitID] = $0 }
        )
    }

    private func suggest() {
        suggesting = true
        errorMessage = nil
        // Only the items the rule-based matcher could not place: Apple
        // Intelligence is the last resort, after learned-transaction matching.
        let pending = pickerItems
        Task {
            defer { suggesting = false; progress = nil }
            do {
                let suggested = try await model.suggestCategoriesForUncategorized(pending)
                for item in pending {
                    if assignments[item.splitID] == nil, let accountID = suggested[item.id] {
                        assignments[item.splitID] = accountID
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Dividend statement import (FR-AI-04)

/// A dividend statement PDF picked for import. Smart Import passes
/// already-extracted details so the sheet opens pre-filled.
struct DividendPayload: Identifiable {
    let id = UUID()
    let data: Data
    var prefilled: DividendStatementDetails?
    /// Original file name — when present, the PDF is stored in the document
    /// folder and linked to the recorded transaction (FR-AI-08).
    var fileName: String?

    init(data: Data, prefilled: DividendStatementDetails? = nil, fileName: String? = nil) {
        self.data = data
        self.prefilled = prefilled
        self.fileName = fileName
    }
}

/// Reads a dividend statement with the on-device model, then lets the user
/// review every figure before the transaction is booked — including the
/// franking-credit gross-up.
struct DividendImportSheet: View {
    @Bindable var model: AppModel
    let payload: DividendPayload
    @Environment(\.dismiss) private var dismiss

    @State private var extracting = true
    @State private var errorMessage: String?
    @State private var securityName = ""
    @State private var ticker = ""
    @State private var paymentDate = Date()
    @State private var frankedText = "0"
    @State private var unfrankedText = "0"
    @State private var creditsText = "0"
    @State private var netText = "0"
    @State private var recordCredits = true
    @State private var cashAccountID: GncGUID?

    private var cashAccounts: [AccountNode] {
        model.postableAccounts.filter {
            ["Bank", "Cash", "Asset"].contains($0.typeName)
        }
    }

    private var franked: Decimal { Decimal(string: frankedText) ?? 0 }
    private var unfranked: Decimal { Decimal(string: unfrankedText) ?? 0 }
    private var credits: Decimal { Decimal(string: creditsText) ?? 0 }
    private var net: Decimal { Decimal(string: netText) ?? 0 }
    private var componentsMatch: Bool { franked + unfranked == net }
    private var canRecord: Bool {
        cashAccountID != nil && net > 0 && componentsMatch && !extracting
    }

    var body: some View {
        NavigationStack {
            Form {
                if extracting {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Reading statement with Apple Intelligence…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Dividend") {
                    TextField("Security", text: $securityName)
                    TextField("Ticker", text: $ticker)
                    DatePicker("Payment date", selection: $paymentDate, displayedComponents: .date)
                }
                Section("Amounts") {
                    TextField("Franked amount", text: $frankedText)
                        .multilineTextAlignment(.trailing).monospacedDigit()
                    TextField("Unfranked amount", text: $unfrankedText)
                        .multilineTextAlignment(.trailing).monospacedDigit()
                    TextField("Franking credits", text: $creditsText)
                        .multilineTextAlignment(.trailing).monospacedDigit()
                    TextField("Net payment", text: $netText)
                        .multilineTextAlignment(.trailing).monospacedDigit()
                    if !componentsMatch {
                        Text("Franked + unfranked should equal the net payment (difference: \(AmountFormat.string(net - franked - unfranked, code: model.reportCurrency.mnemonic))).")
                            .scaledFont(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Section("Booking") {
                    Picker("Deposit into", selection: $cashAccountID) {
                        Text("—").tag(GncGUID?.none)
                        ForEach(cashAccounts) { Text($0.fullName).tag(GncGUID?.some($0.id)) }
                    }
                    Toggle("Record franking credits (gross-up)", isOn: $recordCredits)
                        .help("Adds balancing Income:Dividends:Franking Credits and Assets:Franking Credits Receivable splits — the cash amount is unchanged")
                        .disabled(credits == 0)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).scaledFont(.caption).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Import Dividend Statement")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Record Dividend") { record() }
                        .disabled(!canRecord)
                }
            }
            .task { await extract() }
        }
        .frame(minWidth: 560, minHeight: 500)
    }

    private func extract() async {
        defer { extracting = false }
        if let prefilled = payload.prefilled {
            populate(from: prefilled)
            return
        }
        do {
            let details = try await model.extractDividendStatement(payload.data)
            populate(from: details)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func populate(from details: DividendStatementDetails) {
        securityName = details.securityName
        ticker = details.ticker
        if let date = details.paymentDate { paymentDate = date }
        frankedText = plain(details.frankedAmount)
        unfrankedText = plain(details.unfrankedAmount)
        creditsText = plain(details.frankingCredits)
        netText = plain(details.netPayment)
        recordCredits = details.frankingCredits != 0
        if cashAccountID == nil { cashAccountID = cashAccounts.first?.id }
    }

    private func record() {
        guard let cashAccountID else { return }
        let details = DividendStatementDetails(
            securityName: securityName,
            ticker: ticker,
            paymentDate: paymentDate,
            frankedAmount: franked,
            unfrankedAmount: unfranked,
            frankingCredits: credits,
            netPayment: net
        )
        do {
            let id = try model.recordDividend(details, cashAccountID: cashAccountID,
                                              recordFrankingCredits: recordCredits)
            // Link the statement PDF to the booked transaction (best-effort).
            if let fileName = payload.fileName {
                _ = try? model.attachDocument(named: fileName, data: payload.data, to: id)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func plain(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
}

// MARK: - Budget suggestion (FR-AI-05)

/// Runs the budget advisor over the book's spending history and lets the
/// user accept the proposal line by line.
struct BudgetSuggestSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFontScale) private var appFontScale
    private var amountWidth: CGFloat { 110 * appFontScale }

    @State private var suggestion: BudgetSuggestion?
    @State private var included: Set<GncGUID> = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let errorMessage {
                    ContentUnavailableView("Couldn’t suggest a budget", systemImage: "exclamationmark.triangle",
                                           description: Text(errorMessage))
                } else if let suggestion {
                    Form {
                        Section("Summary") {
                            Text(suggestion.summary)
                            LabeledContent("Suggested total",
                                           value: AmountFormat.string(includedTotal(suggestion),
                                                                      code: model.reportCurrency.mnemonic))
                            LabeledContent("Average monthly income",
                                           value: AmountFormat.string(model.monthlyIncomeAverage(),
                                                                      code: model.reportCurrency.mnemonic))
                        }
                        Section("Proposed monthly amounts") {
                            ForEach(suggestion.lines) { line in
                                row(line)
                            }
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Analysing six months of spending with Apple Intelligence…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Suggest Budget")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply \(included.count)") { apply() }
                        .disabled(included.isEmpty)
                }
            }
            .task { await suggest() }
        }
        .frame(minWidth: 560, minHeight: 480)
    }

    @ViewBuilder
    private func row(_ line: BudgetSuggestionLine) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Toggle("", isOn: Binding(
                get: { included.contains(line.categoryID) },
                set: { isOn in
                    if isOn { included.insert(line.categoryID) } else { included.remove(line.categoryID) }
                }
            ))
            .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(line.fullName)
                Text(line.rationale).scaledFont(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(AmountFormat.string(line.monthlyAmount, code: model.reportCurrency.mnemonic))
                .monospacedDigit()
                .frame(width: amountWidth, alignment: .trailing)
        }
    }

    private func includedTotal(_ suggestion: BudgetSuggestion) -> Decimal {
        suggestion.lines
            .filter { included.contains($0.categoryID) }
            .reduce(0) { $0 + $1.monthlyAmount }
    }

    private func suggest() async {
        do {
            let result = try await model.suggestBudget()
            suggestion = result
            included = Set(result.lines.map(\.categoryID))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func apply() {
        guard let suggestion else { return }
        model.applyBudgetSuggestion(suggestion.lines.filter { included.contains($0.categoryID) })
        dismiss()
    }
}

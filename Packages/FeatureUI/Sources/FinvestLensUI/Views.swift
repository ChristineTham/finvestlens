//
//  Views.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import UniformTypeIdentifiers
import FinvestLensEngine

/// A GnuCash XML file for `.fileExporter` (export only).
struct GnuCashFileDocument: FileDocument {
    static let contentType = UTType(filenameExtension: "gnucash") ?? .xml
    static var readableContentTypes: [UTType] { [contentType, .xml] }

    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Formatting

enum AmountFormat {
    static func string(_ value: Decimal, code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        return formatter.string(from: NSDecimalNumber(decimal: value))
            ?? "\(value) \(code)"
    }
}

/// Applies keyboard focus a beat after a sheet finishes presenting, so very
/// fast input (or automation) can't precede the field gaining focus.
@MainActor
func focusSoon(_ apply: @escaping @MainActor () -> Void) {
    Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(120))
        apply()
    }
}

public extension AppModel {
    /// Flattened, non-placeholder accounts usable as transfer endpoints.
    var postableAccounts: [AccountNode] {
        func flatten(_ nodes: [AccountNode]) -> [AccountNode] {
            nodes.flatMap { [$0] + flatten($0.children ?? []) }
        }
        return flatten(accountTree).filter { !$0.isPlaceholder }
    }
}

// MARK: - Root

/// The main document view: accounts sidebar + register (or search results).
public struct FinvestLensRootView: View {
    @Bindable var model: AppModel
    @State private var showingNewAccount = false
    @State private var showingNewTransaction = false
    @State private var showingExport = false
    @State private var exportDocument: GnuCashFileDocument?
    @State private var showingReports = false
    @State private var showingBankImport = false
    @State private var importPayload: ImportPayload?
    @State private var showingRules = false
    @State private var showingScheduled = false
    @State private var showingBudget = false
    @State private var showingPrices = false
    @State private var showingStockTxn = false
    @State private var showingCurrencyTransfer = false
    @State private var showingSaveSearch = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            AccountsSidebar(model: model)
                .navigationTitle("Accounts")
        } detail: {
            if !model.searchResults.isEmpty {
                SearchResultsView(model: model)
            } else {
                RegisterView(model: model)
            }
        }
        .searchable(text: $model.searchQuery, prompt: "Search transactions")
        .toolbar {
            ToolbarItemGroup {
                Button("New Account", systemImage: "plus.rectangle.on.folder") {
                    showingNewAccount = true
                }
                Button("New Transaction", systemImage: "plus.circle") {
                    showingNewTransaction = true
                }
                .disabled(model.postableAccounts.count < 2)
                Button("Stock Transaction", systemImage: "chart.line.uptrend.xyaxis") {
                    showingStockTxn = true
                }
                .disabled(model.securityAccountNodes.isEmpty)
                Button("Currency Transfer", systemImage: "dollarsign.arrow.circlepath") {
                    showingCurrencyTransfer = true
                }
                .disabled(model.currencyCommodities.count < 2)
                Button("Reports", systemImage: "chart.pie") {
                    showingReports = true
                }
                Button("Import Bank File…", systemImage: "square.and.arrow.down.on.square") {
                    showingBankImport = true
                }
                Button("Rules", systemImage: "wand.and.stars") {
                    showingRules = true
                }
                Button("Scheduled", systemImage: "calendar.badge.clock") {
                    showingScheduled = true
                }
                Button("Budget", systemImage: "chart.bar.doc.horizontal") {
                    showingBudget = true
                }
                Button("Prices", systemImage: "tag") {
                    showingPrices = true
                }
                Menu {
                    if model.savedSearches.isEmpty {
                        Text("No saved searches")
                    } else {
                        ForEach(model.savedSearches) { search in
                            Menu(search.name) {
                                Button("Apply") { model.applySavedSearch(search.id) }
                                Button("Delete", role: .destructive) { model.deleteSavedSearch(search.id) }
                            }
                        }
                    }
                    Divider()
                    Button("Save current search…") { showingSaveSearch = true }
                        .disabled(model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                } label: {
                    Label("Saved Searches", systemImage: "bookmark")
                }
                Button("Save", systemImage: "square.and.arrow.down") {
                    try? model.save()
                }
                .disabled(!model.hasUnsavedChanges)
                Button("Export GnuCash…", systemImage: "arrow.up.doc") {
                    if let data = model.gnuCashExportData() {
                        exportDocument = GnuCashFileDocument(data: data)
                        showingExport = true
                    }
                }
            }
        }
        .sheet(isPresented: $showingNewAccount) {
            NewAccountSheet(model: model)
        }
        .sheet(isPresented: $showingNewTransaction) {
            TransactionEditorSheet(model: model)
        }
        .sheet(isPresented: $showingReports) {
            ReportsView(model: model)
        }
        .fileImporter(isPresented: $showingBankImport, allowedContentTypes: [.commaSeparatedText, .text, .data]) { result in
            if case .success(let url) = result { loadBankFile(url) }
        }
        .sheet(item: $importPayload) { payload in
            ImportView(model: model, payload: payload)
        }
        .sheet(isPresented: $showingRules) {
            RulesView(model: model)
        }
        .sheet(isPresented: $showingScheduled) {
            ScheduledView(model: model)
        }
        .sheet(isPresented: $showingBudget) {
            BudgetView(model: model)
        }
        .sheet(isPresented: $showingPrices) {
            PricesView(model: model)
        }
        .sheet(isPresented: $showingStockTxn) {
            StockTransactionSheet(model: model)
        }
        .sheet(isPresented: $showingCurrencyTransfer) {
            CurrencyTransferSheet(model: model)
        }
        .sheet(isPresented: $showingSaveSearch) {
            SaveSearchSheet(model: model)
        }
        .fileExporter(isPresented: $showingExport, document: exportDocument,
                      contentType: GnuCashFileDocument.contentType, defaultFilename: "Book") { _ in
            exportDocument = nil
        }
    }

    private func loadBankFile(_ url: URL) {
        guard let format = BankFileFormat.forExtension(url.pathExtension) else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        importPayload = ImportPayload(data: data, format: format)
    }
}

// MARK: - Accounts sidebar

/// Which modal a sidebar account row is presenting.
enum AccountSheet: Identifiable {
    case edit(GncGUID)
    case reconcile(GncGUID)

    var id: String {
        switch self {
        case .edit(let guid): return "edit-\(guid.hexString)"
        case .reconcile(let guid): return "rec-\(guid.hexString)"
        }
    }
}

struct AccountsSidebar: View {
    @Bindable var model: AppModel
    @State private var sheet: AccountSheet?

    var body: some View {
        List(selection: $model.selectedAccountID) {
            OutlineGroup(model.accountTree, children: \.children) { node in
                HStack {
                    Text(node.name)
                        .foregroundStyle(node.isHidden ? .secondary : .primary)
                    Spacer()
                    Text(AmountFormat.string(node.balance, code: node.currencyCode))
                        .monospacedDigit()
                        .foregroundStyle(node.balance < 0 ? .red : .secondary)
                }
                .tag(node.id)
                .contextMenu {
                    Button("Edit…") { sheet = .edit(node.id) }
                    Button("Reconcile…") { sheet = .reconcile(node.id) }
                    if model.canDeleteAccount(node.id) {
                        Button("Delete", role: .destructive) { model.deleteAccount(node.id) }
                    }
                }
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .edit(let id): EditAccountSheet(model: model, accountID: id)
            case .reconcile(let id): ReconcileView(model: model, accountID: id)
            }
        }
    }
}

// MARK: - Register

struct RegisterView: View {
    @Bindable var model: AppModel
    @State private var selection: Set<GncGUID> = []
    @State private var editingTransactionID: GncGUID?

    var body: some View {
        Group {
            if model.selectedAccountID == nil {
                ContentUnavailableView("Select an account",
                                       systemImage: "list.bullet.rectangle",
                                       description: Text("Choose an account to see its transactions."))
            } else if model.registerRows.isEmpty {
                ContentUnavailableView("No transactions",
                                       systemImage: "tray",
                                       description: Text("This account has no postings yet."))
            } else {
                registerTable
            }
        }
        .navigationTitle(selectedName)
    }

    private var registerTable: some View {
        Table(model.registerRows, selection: $selection) {
            TableColumn("Date") { row in
                Text(row.date, format: .dateTime.year().month().day())
            }
            TableColumn("Description", value: \.description)
            TableColumn("Transfer", value: \.transfer)
            TableColumn("R") { row in
                Button(row.reconcile) { model.cycleReconcileState(splitID: row.id) }
                    .buttonStyle(.plain)
                    .frame(width: 16)
            }
            TableColumn("Amount") { row in
                Text(AmountFormat.string(row.amount, code: currencyCode))
                    .monospacedDigit()
                    .foregroundStyle(row.amount < 0 ? .red : .primary)
            }
            TableColumn("Balance") { row in
                Text(AmountFormat.string(row.runningBalance, code: currencyCode))
                    .monospacedDigit()
            }
        }
        .contextMenu(forSelectionType: GncGUID.self) { ids in
            if let splitID = ids.first, let txnID = model.transactionID(ofSplit: splitID) {
                Button("Edit…") { editingTransactionID = txnID }
                Button("Go to Other Account") { model.jumpToOtherAccount(ofSplit: splitID) }
                Divider()
                Button("Duplicate") { model.duplicateTransaction(txnID) }
                Button("Add Reversing Transaction") { _ = model.addReversingTransaction(txnID) }
                Button("Void") { model.voidTransaction(txnID) }
                Divider()
                Button("Delete", role: .destructive) { model.deleteTransaction(txnID) }
            }
        }
        .sheet(item: $editingTransactionID) { id in
            TransactionEditorSheet(model: model, editingID: id)
        }
    }

    private var selectedName: String {
        model.postableAccounts.first { $0.id == model.selectedAccountID }?.name
            ?? model.accountTree.first { $0.id == model.selectedAccountID }?.name
            ?? "Register"
    }

    private var currencyCode: String {
        model.postableAccounts.first { $0.id == model.selectedAccountID }?.currencyCode ?? "AUD"
    }
}

// MARK: - Search results

struct SearchResultsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Table(model.searchResults) {
            TableColumn("Date") { row in
                Text(row.date, format: .dateTime.year().month().day())
            }
            TableColumn("Description", value: \.description)
            TableColumn("Accounts", value: \.accounts)
            TableColumn("Amount") { row in
                Text(AmountFormat.string(row.amount, code: row.currencyCode))
                    .monospacedDigit()
            }
        }
        .navigationTitle("Results for “\(model.searchQuery)”")
    }
}

// MARK: - New account

/// A small catalog of common ISO currencies for the account editor.
enum CurrencyCatalog {
    static let common: [Commodity] = [
        .currency("AUD", name: "Australian Dollar"),
        .currency("USD", name: "US Dollar"),
        .currency("EUR", name: "Euro"),
        .currency("GBP", name: "Pound Sterling"),
        .currency("NZD", name: "New Zealand Dollar"),
        .currency("CAD", name: "Canadian Dollar"),
        .currency("JPY", fractionDigits: 0, name: "Japanese Yen"),
        .currency("CHF", name: "Swiss Franc"),
        .currency("CNY", name: "Chinese Yuan"),
        .currency("HKD", name: "Hong Kong Dollar"),
        .currency("SGD", name: "Singapore Dollar"),
        .currency("INR", name: "Indian Rupee"),
    ]
}

/// Names and saves the current search query.
struct SaveSearchSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Query", value: model.searchQuery)
                TextField("Name", text: $name).focused($focused)
            }
            .navigationTitle("Save Search")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { model.saveCurrentSearch(name: name); dismiss() }
                }
            }
            .onAppear { focusSoon { focused = true } }
        }
        .frame(minWidth: 360, minHeight: 160)
    }
}

struct NewAccountSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var type: AccountType = .bank
    @State private var parentID: GncGUID?
    @State private var currencyCode = ""
    @State private var exchange = ""
    @State private var ticker = ""
    @State private var securityName = ""
    @FocusState private var nameFocused: Bool

    private let selectableTypes: [AccountType] = [
        .bank, .cash, .asset, .credit, .liability, .equity, .income, .expense, .stock, .mutualFund,
    ]

    private var isSecurity: Bool { type.isSecurityType }

    /// Book currencies plus the common catalog, de-duplicated by code.
    private var availableCurrencies: [Commodity] {
        var seen = Set<String>()
        var result: [Commodity] = []
        for commodity in model.currencyCommodities + CurrencyCatalog.common
        where seen.insert(commodity.mnemonic).inserted {
            result.append(commodity)
        }
        return result
    }

    private var canAdd: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return isSecurity ? !ticker.trimmingCharacters(in: .whitespaces).isEmpty : true
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .focused($nameFocused)
                Picker("Type", selection: $type) {
                    ForEach(selectableTypes, id: \.self) { t in
                        Text(t.rawValue.capitalized).tag(t)
                    }
                }
                Picker("Parent", selection: $parentID) {
                    Text("Top level").tag(GncGUID?.none)
                    ForEach(model.accountTree) { node in
                        Text(node.name).tag(GncGUID?.some(node.id))
                    }
                }

                if isSecurity {
                    Section("Security") {
                        TextField("Exchange (e.g. ASX)", text: $exchange)
                        TextField("Ticker (e.g. CBA)", text: $ticker)
                        TextField("Full name (optional)", text: $securityName)
                    }
                } else {
                    Picker("Currency", selection: $currencyCode) {
                        ForEach(availableCurrencies, id: \.mnemonic) { c in
                            Text("\(c.mnemonic) — \(c.fullName)").tag(c.mnemonic)
                        }
                    }
                }
            }
            .navigationTitle("New Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }.disabled(!canAdd)
                }
            }
            .onAppear {
                if currencyCode.isEmpty { currencyCode = model.reportCurrency.mnemonic }
                focusSoon { nameFocused = true }
            }
        }
    }

    private func makeCommodity() -> Commodity {
        if isSecurity {
            let code = ticker.trimmingCharacters(in: .whitespaces).uppercased()
            let ex = exchange.trimmingCharacters(in: .whitespaces).uppercased()
            let full = securityName.trimmingCharacters(in: .whitespaces)
            return Commodity(namespace: .security(ex.isEmpty ? "OTHER" : ex),
                             mnemonic: code,
                             fullName: full.isEmpty ? code : full,
                             smallestFraction: 10_000)
        }
        return availableCurrencies.first { $0.mnemonic == currencyCode } ?? .currency(currencyCode)
    }

    private func add() {
        model.addAccount(name: name, type: type, commodity: makeCommodity(), parentID: parentID)
        dismiss()
    }
}

// MARK: - Transaction editor (multi-split)

private struct EditableSplit: Identifiable {
    let id = UUID()
    var accountID: GncGUID?
    var amountText: String = ""

    var amount: Decimal { Decimal(string: amountText) ?? 0 }

    init(accountID: GncGUID? = nil, amountText: String = "") {
        self.accountID = accountID
        self.amountText = amountText
    }

    init(_ input: SplitInput) {
        self.accountID = input.accountID
        self.amountText = NSDecimalNumber(decimal: input.value).stringValue
    }
}

/// Creates or edits a transaction with N balancing splits, with QuickFill.
struct TransactionEditorSheet: View {
    @Bindable var model: AppModel
    var editingID: GncGUID?
    @Environment(\.dismiss) private var dismiss

    @State private var loaded = false
    @State private var date = Date()
    @State private var description = ""
    @State private var tagsText = ""
    @State private var lines: [EditableSplit] = [EditableSplit(), EditableSplit()]
    @FocusState private var descriptionFocused: Bool

    private var parsedTags: [String] {
        tagsText.split(whereSeparator: { $0 == "," || $0 == " " })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var imbalance: Decimal { lines.reduce(Decimal(0)) { $0 + $1.amount } }
    private var validLineCount: Int { lines.filter { $0.accountID != nil }.count }
    private var isBalanced: Bool { imbalance == 0 && validLineCount >= 2 }
    private var isEditing: Bool { editingID != nil }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TextField("Description", text: $description)
                    .focused($descriptionFocused)
                if !isEditing {
                    let suggestions = model.descriptionSuggestions(prefix: description)
                    if !suggestions.isEmpty {
                        Menu("Fill from recent…") {
                            ForEach(suggestions, id: \.self) { suggestion in
                                Button(suggestion) { applyTemplate(suggestion) }
                            }
                        }
                    }
                }

                Section("Splits") {
                    ForEach($lines) { $line in
                        HStack {
                            Picker("Account", selection: $line.accountID) {
                                Text("—").tag(GncGUID?.none)
                                ForEach(model.postableAccounts) { node in
                                    Text(node.fullName).tag(GncGUID?.some(node.id))
                                }
                            }
                            .labelsHidden()
                            TextField("Amount", text: $line.amountText)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 100)
                        }
                    }
                    .onDelete { lines.remove(atOffsets: $0) }
                    Button("Add Split", systemImage: "plus") { lines.append(EditableSplit()) }
                }

                Section("Tags") {
                    TextField("Comma-separated tags", text: $tagsText)
                }

                Section {
                    HStack {
                        Text("Imbalance")
                        Spacer()
                        Text(AmountFormat.string(imbalance, code: "AUD"))
                            .monospacedDigit()
                            .foregroundStyle(imbalance == 0 ? Color.secondary : Color.red)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Transaction" : "New Transaction")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") { commit() }
                        .disabled(!isBalanced)
                }
            }
            .onAppear(perform: loadIfNeeded)
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let editingID, let edit = model.editData(forTransaction: editingID) {
            date = edit.date
            description = edit.description
            lines = edit.splits.map { EditableSplit($0) }
            tagsText = edit.tags.joined(separator: ", ")
        }
        focusSoon { descriptionFocused = true }
    }

    private func applyTemplate(_ suggestion: String) {
        description = suggestion
        if let template = model.template(forDescription: suggestion) {
            lines = template.map { EditableSplit($0) }
        }
    }

    private func commit() {
        let inputs = lines
            .filter { $0.accountID != nil }
            .map { SplitInput(accountID: $0.accountID, value: $0.amount) }
        if let editingID {
            _ = try? model.updateTransaction(id: editingID, date: date, description: description,
                                             currency: .aud, splits: inputs, tags: parsedTags)
        } else {
            _ = try? model.addTransaction(date: date, description: description,
                                          currency: .aud, splits: inputs, tags: parsedTags)
        }
        dismiss()
    }
}

// MARK: - Edit account

struct EditAccountSheet: View {
    @Bindable var model: AppModel
    let accountID: GncGUID
    @Environment(\.dismiss) private var dismiss

    @State private var loaded = false
    @State private var name = ""
    @State private var code = ""
    @State private var description = ""
    @State private var notes = ""
    @State private var isPlaceholder = false
    @State private var isHidden = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .focused($nameFocused)
                TextField("Code", text: $code)
                TextField("Description", text: $description)
                TextField("Notes", text: $notes, axis: .vertical)
                Toggle("Placeholder", isOn: $isPlaceholder)
                Toggle("Hidden", isOn: $isHidden)

                Section {
                    Button("Renumber sub-accounts") {
                        model.renumberChildren(of: accountID)
                    }
                } footer: {
                    Text("Assigns sequential codes (010, 020, …) to this account's children.")
                }
            }
            .navigationTitle("Edit Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.updateAccount(id: accountID, name: name, code: code,
                                            description: description, notes: notes,
                                            isPlaceholder: isPlaceholder, isHidden: isHidden)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if !loaded, let edit = model.editData(forAccount: accountID) {
                    loaded = true
                    name = edit.name; code = edit.code; description = edit.description
                    notes = edit.notes; isPlaceholder = edit.isPlaceholder; isHidden = edit.isHidden
                }
                focusSoon { nameFocused = true }
            }
        }
    }
}

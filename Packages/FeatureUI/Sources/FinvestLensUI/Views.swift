//
//  Views.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine

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

/// The main document view: accounts sidebar + register detail.
public struct FinvestLensRootView: View {
    @Bindable var model: AppModel
    @State private var showingNewAccount = false
    @State private var showingNewTransaction = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            AccountsSidebar(model: model)
                .navigationTitle("Accounts")
        } detail: {
            RegisterView(model: model)
        }
        .toolbar {
            ToolbarItemGroup {
                Button("New Account", systemImage: "plus.rectangle.on.folder") {
                    showingNewAccount = true
                }
                Button("New Transaction", systemImage: "plus.circle") {
                    showingNewTransaction = true
                }
                .disabled(model.postableAccounts.count < 2)
                Button("Save", systemImage: "square.and.arrow.down") {
                    try? model.save()
                }
                .disabled(!model.hasUnsavedChanges)
            }
        }
        .sheet(isPresented: $showingNewAccount) {
            NewAccountSheet(model: model)
        }
        .sheet(isPresented: $showingNewTransaction) {
            NewTransactionSheet(model: model)
        }
    }
}

// MARK: - Accounts sidebar

struct AccountsSidebar: View {
    @Bindable var model: AppModel

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
            }
        }
    }
}

// MARK: - Register

struct RegisterView: View {
    @Bindable var model: AppModel

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
                Table(model.registerRows) {
                    TableColumn("Date") { row in
                        Text(row.date, format: .dateTime.year().month().day())
                    }
                    TableColumn("Description", value: \.description)
                    TableColumn("Transfer", value: \.transfer)
                    TableColumn("R", value: \.reconcile)
                    TableColumn("Amount") { row in
                        Text(AmountFormat.string(row.amount, code: currencyCode))
                            .monospacedDigit()
                    }
                    TableColumn("Balance") { row in
                        Text(AmountFormat.string(row.runningBalance, code: currencyCode))
                            .monospacedDigit()
                    }
                }
            }
        }
        .navigationTitle(selectedName)
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

// MARK: - New account

struct NewAccountSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var type: AccountType = .bank
    @State private var parentID: GncGUID?

    private let selectableTypes: [AccountType] = [
        .bank, .cash, .asset, .credit, .liability, .equity, .income, .expense, .stock, .mutualFund,
    ]

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
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
            }
            .navigationTitle("New Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        model.addAccount(name: name, type: type, parentID: parentID)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - New transaction

struct NewTransactionSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var description = ""
    @State private var amountText = ""
    @State private var sourceID: GncGUID?
    @State private var destinationID: GncGUID?

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TextField("Description", text: $description)
                TextField("Amount", text: $amountText)
                Picker("From", selection: $sourceID) {
                    Text("—").tag(GncGUID?.none)
                    ForEach(model.postableAccounts) { node in
                        Text(node.fullName).tag(GncGUID?.some(node.id))
                    }
                }
                Picker("To", selection: $destinationID) {
                    Text("—").tag(GncGUID?.none)
                    ForEach(model.postableAccounts) { node in
                        Text(node.fullName).tag(GncGUID?.some(node.id))
                    }
                }
            }
            .navigationTitle("New Transaction")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let source = sourceID, let destination = destinationID,
                           let amount = Decimal(string: amountText) {
                            model.addTransfer(from: source, to: destination,
                                              amount: amount, date: date, description: description)
                        }
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }

    private var isValid: Bool {
        guard let sourceID, let destinationID, sourceID != destinationID else { return false }
        guard let amount = Decimal(string: amountText), amount != 0 else { return false }
        return true
    }
}

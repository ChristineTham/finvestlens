//
//  StockTransactionSheet.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine

/// The Stock Transaction Assistant: guided entry for buys, sells, dividends and
/// reinvestments (`FR-INV-05`).
struct StockTransactionSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var action: StockActionKind = .buy
    @State private var securityID: GncGUID?
    @State private var settlementID: GncGUID?
    @State private var incomeID: GncGUID?
    @State private var commissionID: GncGUID?
    @State private var date = Date()
    @State private var description = ""
    @State private var sharesText = ""
    @State private var priceText = ""
    @State private var amountText = ""
    @State private var commissionText = ""
    @State private var splitNewText = "2"
    @State private var splitOldText = "1"
    @State private var memo = ""
    @State private var errorText: String?

    private var shares: Decimal? { Decimal(string: sharesText) }
    private var price: Decimal? { Decimal(string: priceText) }
    private var amount: Decimal? { Decimal(string: amountText) }
    private var commission: Decimal { Decimal(string: commissionText) ?? 0 }
    private var splitNew: Decimal? { Decimal(string: splitNewText) }
    private var splitOld: Decimal? { Decimal(string: splitOldText) }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Action", selection: $action) {
                    ForEach(StockActionKind.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)

                accountsSection
                amountsSection

                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Description", text: $description)
                    TextField("Memo (optional)", text: $memo)
                }

                if let total = previewTotal {
                    LabeledContent(previewLabel) {
                        Text(AmountFormat.string(total, code: settlementCode)).monospacedDigit()
                    }
                }
                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Stock Transaction")
            .onExitCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Record") { record() }.disabled(!isValid)
                }
            }
            .onAppear(perform: prime)
        }
        .frame(minWidth: 460, minHeight: 520)
    }

    // MARK: Sections

    @ViewBuilder
    private var accountsSection: some View {
        Section("Accounts") {
            if action != .dividend {
                accountPicker("Security", selection: $securityID, nodes: model.securityAccountNodes)
            }
            if action != .reinvestDividend && action != .split {
                accountPicker(action == .dividend || action == .returnOfCapital ? "Deposit to" : "Settlement",
                              selection: $settlementID, nodes: model.settlementAccountNodes)
            }
            if action == .dividend || action == .reinvestDividend {
                accountPicker("Income", selection: $incomeID, nodes: model.incomeAccountNodes)
            }
            if action == .buy || action == .sell {
                accountPicker("Commission (optional)", selection: $commissionID,
                              nodes: model.expenseAccountNodes, allowNone: true)
            }
        }
    }

    @ViewBuilder
    private var amountsSection: some View {
        Section("Amounts") {
            switch action {
            case .buy, .sell:
                numberField("Shares", text: $sharesText)
                numberField("Price per share", text: $priceText)
                numberField("Commission", text: $commissionText)
            case .dividend, .returnOfCapital:
                numberField("Amount", text: $amountText)
            case .reinvestDividend:
                numberField("Shares", text: $sharesText)
                numberField("Amount", text: $amountText)
            case .split:
                numberField("New shares", text: $splitNewText)
                numberField("Per old shares", text: $splitOldText)
                if let resulting = splitResultingShares {
                    LabeledContent("Resulting shares") {
                        Text(resulting.formatted()).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var splitResultingShares: Decimal? {
        guard let new = splitNew, let old = splitOld, old != 0,
              let balance = model.securityAccountNodes.first(where: { $0.id == securityID })?.balance
        else { return nil }
        return balance * new / old
    }

    private func accountPicker(_ label: String, selection: Binding<GncGUID?>,
                               nodes: [AccountNode], allowNone: Bool = false) -> some View {
        Picker(label, selection: selection) {
            if allowNone { Text("None").tag(GncGUID?.none) }
            ForEach(nodes) { Text($0.fullName).tag(GncGUID?.some($0.id)) }
        }
    }

    private func numberField(_ label: String, text: Binding<String>) -> some View {
        TextField(label, text: text)
            .multilineTextAlignment(.trailing)
        #if os(iOS)
            .keyboardType(.decimalPad)
        #endif
    }

    // MARK: Derived

    private var settlementCode: String {
        model.settlementAccountNodes.first { $0.id == settlementID }?.currencyCode
            ?? model.reportCurrency.mnemonic
    }

    private var previewLabel: String {
        switch action {
        case .buy: return "Total cost"
        case .sell: return "Net proceeds"
        case .dividend, .reinvestDividend, .returnOfCapital: return "Amount"
        case .split: return ""
        }
    }

    private var previewTotal: Decimal? {
        switch action {
        case .buy:
            guard let shares, let price else { return nil }
            return shares * price + commission
        case .sell:
            guard let shares, let price else { return nil }
            return shares * price - commission
        case .dividend, .reinvestDividend, .returnOfCapital:
            return amount
        case .split:
            return nil
        }
    }

    private var isValid: Bool {
        guard settlementValid else { return false }
        switch action {
        case .buy, .sell:
            return securityID != nil && (shares ?? 0) > 0 && (price ?? 0) > 0
        case .dividend:
            return incomeID != nil && (amount ?? 0) > 0
        case .reinvestDividend:
            return securityID != nil && incomeID != nil && (amount ?? 0) > 0 && (shares ?? 0) > 0
        case .split:
            return securityID != nil && (splitNew ?? 0) > 0 && (splitOld ?? 0) > 0
        case .returnOfCapital:
            return securityID != nil && (amount ?? 0) > 0
        }
    }

    private var settlementValid: Bool {
        action == .reinvestDividend || action == .split || settlementID != nil
    }

    // MARK: Actions

    private func prime() {
        if securityID == nil { securityID = model.securityAccountNodes.first?.id }
        if settlementID == nil { settlementID = model.settlementAccountNodes.first?.id }
        if incomeID == nil { incomeID = model.incomeAccountNodes.first?.id }
    }

    private func record() {
        errorText = nil
        let name = description.isEmpty ? defaultDescription : description
        do {
            try model.recordStockTransaction(
                action: action, securityID: securityID, settlementID: settlementID,
                incomeID: incomeID, commissionID: commissionID,
                shares: shares ?? 0, pricePerShare: price ?? 0, amount: amount ?? 0,
                commission: commission, splitNew: splitNew ?? 0, splitOld: splitOld ?? 0,
                date: date, description: name, memo: memo)
            dismiss()
        } catch {
            errorText = "Couldn’t record: \(error)"
        }
    }

    private var defaultDescription: String {
        let symbol = model.securityAccountNodes.first { $0.id == securityID }?.name ?? "Security"
        return "\(action.displayName) \(symbol)"
    }
}

//
//  CurrencyTransferSheet.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine

/// Guided entry for a transfer between accounts in different currencies
/// (`FR-CUR-02`).
struct CurrencyTransferSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var fromID: GncGUID?
    @State private var toID: GncGUID?
    @State private var date = Date()
    @State private var description = ""
    @State private var sourceText = ""
    @State private var destText = ""
    @State private var errorText: String?

    private var accounts: [AccountNode] { model.settlementAccountNodes }
    private var sourceAmount: Decimal? { Decimal(string: sourceText) }
    private var destAmount: Decimal? { Decimal(string: destText) }

    private var fromCode: String { accounts.first { $0.id == fromID }?.currencyCode ?? "" }
    private var toCode: String { accounts.first { $0.id == toID }?.currencyCode ?? "" }

    var body: some View {
        NavigationStack {
            Form {
                Section("Accounts") {
                    Picker("From", selection: $fromID) {
                        ForEach(accounts) { Text($0.fullName).tag(GncGUID?.some($0.id)) }
                    }
                    Picker("To", selection: $toID) {
                        ForEach(accounts) { Text($0.fullName).tag(GncGUID?.some($0.id)) }
                    }
                }
                Section("Amounts") {
                    amountField("Amount out\(fromCode.isEmpty ? "" : " (\(fromCode))")", text: $sourceText)
                    amountField("Amount in\(toCode.isEmpty ? "" : " (\(toCode))")", text: $destText)
                    if let rate = impliedRate {
                        LabeledContent("Implied rate") {
                            Text("1 \(fromCode) = \(rate.formatted(.number.precision(.fractionLength(0...6)))) \(toCode)")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Description", text: $description)
                }
                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Currency Transfer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Transfer") { record() }.disabled(!isValid)
                }
            }
            .onAppear(perform: prime)
        }
        .frame(minWidth: 440, minHeight: 420)
    }

    private func amountField(_ label: String, text: Binding<String>) -> some View {
        TextField(label, text: text)
            .multilineTextAlignment(.trailing)
        #if os(iOS)
            .keyboardType(.decimalPad)
        #endif
    }

    private var impliedRate: Decimal? {
        guard let source = sourceAmount, source > 0, let dest = destAmount else { return nil }
        return dest / source
    }

    private var isValid: Bool {
        fromID != nil && toID != nil && fromCode != toCode
            && (sourceAmount ?? 0) > 0 && (destAmount ?? 0) > 0
    }

    private func prime() {
        if fromID == nil { fromID = accounts.first?.id }
        if toID == nil { toID = accounts.first { $0.currencyCode != fromCode }?.id ?? accounts.dropFirst().first?.id }
    }

    private func record() {
        errorText = nil
        let name = description.isEmpty ? "Currency transfer" : description
        do {
            try model.recordCurrencyTransfer(
                fromID: fromID, toID: toID,
                sourceAmount: sourceAmount ?? 0, destAmount: destAmount ?? 0,
                date: date, description: name)
            dismiss()
        } catch {
            errorText = "Couldn’t transfer: \(error)"
        }
    }
}

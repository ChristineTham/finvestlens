//
//  SecuritiesView.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine

/// Lists securities (held + watched), edits their display name, and manages the
/// watch list (`FR-INV-07`, `FR-PLAN-07`).
struct SecuritiesView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: EditTarget?
    @State private var showingAddWatch = false

    private struct EditTarget: Identifiable {
        let commodity: Commodity
        var id: String { "\(commodity.namespace)|\(commodity.mnemonic)" }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Securities") {
                    if model.pricableSecurities.isEmpty {
                        Text("No securities yet.").foregroundStyle(.secondary)
                    }
                    ForEach(model.pricableSecurities, id: \.self) { commodity in
                        HStack {
                            VStack(alignment: .leading) {
                                HStack {
                                    Text(commodity.mnemonic).fontWeight(.medium)
                                    if model.isWatchOnly(commodity) {
                                        Text("watch").scaledFont(.caption2)
                                            .padding(.horizontal, 4).background(.blue.opacity(0.2)).clipShape(Capsule())
                                    }
                                }
                                Text(commodity.fullName).scaledFont(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let price = model.book?.latestPrice(of: commodity, in: model.reportCurrency)?.value {
                                Text(AmountFormat.string(price, code: model.reportCurrency.mnemonic))
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
                            Button("Edit") { editing = EditTarget(commodity: commodity) }.buttonStyle(.borderless)
                            if model.isWatchOnly(commodity) {
                                Button(role: .destructive) { model.removeWatchSecurity(commodity) } label: {
                                    Image(systemName: "trash")
                                }.buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(commodity.mnemonic) from watch list")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Securities")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem {
                    Button("Watch Security", systemImage: "eye") { showingAddWatch = true }
                }
            }
            .sheet(item: $editing) { target in
                EditSecuritySheet(model: model, commodity: target.commodity)
            }
            .sheet(isPresented: $showingAddWatch) { AddWatchSheet(model: model) }
        }
        .frame(minWidth: 460, minHeight: 380)
    }
}

/// Edits a security's display name and fraction across all holdings.
private struct EditSecuritySheet: View {
    @Bindable var model: AppModel
    let commodity: Commodity
    @Environment(\.dismiss) private var dismiss
    @State private var fullName = ""

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Ticker", value: commodity.mnemonic)
                LabeledContent("Exchange", value: namespaceLabel)
                TextField("Full name", text: $fullName)
            }
            .navigationTitle("Edit Security")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { model.renameSecurity(commodity, fullName: fullName); dismiss() }
                        .disabled(fullName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { fullName = commodity.fullName }
        }
        .frame(minWidth: 360, minHeight: 180)
    }

    private var namespaceLabel: String {
        if case let .security(exchange) = commodity.namespace { return exchange }
        return "—"
    }
}

/// Adds a security to the watch list (no holding).
private struct AddWatchSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var exchange = ""
    @State private var ticker = ""
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Exchange (e.g. NASDAQ)", text: $exchange)
                TextField("Ticker (e.g. AAPL)", text: $ticker)
                TextField("Full name (optional)", text: $name)
            }
            .navigationTitle("Watch Security")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        model.addWatchSecurity(exchange: exchange, ticker: ticker, name: name)
                        dismiss()
                    }
                    .disabled(ticker.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 200)
    }
}

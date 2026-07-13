//
//  SecuritiesView.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine
import FinvestLensReports

/// Lists securities (held + watched), edits their display name, and manages the
/// watch list (`FR-INV-07`, `FR-PLAN-07`).
struct SecuritiesView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: EditTarget?
    @State private var settingTarget: EditTarget?
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
                        SecurityRow(model: model, commodity: commodity,
                                    onTarget: { settingTarget = EditTarget(commodity: commodity) },
                                    onEdit: { editing = EditTarget(commodity: commodity) })
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
            .sheet(item: $settingTarget) { target in
                PriceTargetSheet(model: model, commodity: target.commodity)
            }
            .sheet(isPresented: $showingAddWatch) { AddWatchSheet(model: model) }
        }
        .frame(minWidth: 460, minHeight: 380)
    }
}

/// One row of the securities list: identity, latest price, target/edit actions.
private struct SecurityRow: View {
    @Bindable var model: AppModel
    let commodity: Commodity
    let onTarget: () -> Void
    let onEdit: () -> Void

    private var code: String { model.reportCurrency.mnemonic }

    var body: some View {
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
                if let target = model.priceTarget(for: commodity) {
                    let word = target.direction == .atOrAbove ? "above" : "below"
                    Text("Alert \(word) \(AmountFormat.string(target.target, code: code))")
                        .scaledFont(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            if let price = model.book?.latestPrice(of: commodity, in: model.reportCurrency)?.value {
                Text(AmountFormat.string(price, code: code))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Button("Target…", action: onTarget)
                .buttonStyle(.borderless)
                .accessibilityLabel("Set price target for \(commodity.mnemonic)")
            Button("Edit", action: onEdit).buttonStyle(.borderless)
            if model.isWatchOnly(commodity) {
                Button(role: .destructive) { model.removeWatchSecurity(commodity) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(commodity.mnemonic) from watch list")
            }
        }
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

/// Sets (or clears) a price target that raises a dashboard alert when the
/// latest quote crosses it (`FR-PLAN-05`).
private struct PriceTargetSheet: View {
    @Bindable var model: AppModel
    let commodity: Commodity
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var direction: PriceTarget.Direction = .atOrAbove

    private var hasExisting: Bool { model.priceTarget(for: commodity) != nil }

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Security", value: commodity.mnemonic)
                if let price = model.book?.latestPrice(of: commodity, in: model.reportCurrency)?.value {
                    LabeledContent("Latest price",
                                   value: AmountFormat.string(price, code: model.reportCurrency.mnemonic))
                }
                Picker("Alert when price is", selection: $direction) {
                    Text("Above").tag(PriceTarget.Direction.atOrAbove)
                    Text("Below").tag(PriceTarget.Direction.atOrBelow)
                }
                .pickerStyle(.segmented)
                TextField("Target price", text: $amount)
                    .multilineTextAlignment(.trailing)
                Text("You’ll see an alert on the dashboard when the latest quote crosses this target.")
                    .scaledFont(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("Price Target")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if hasExisting {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Remove Target", role: .destructive) {
                            model.removePriceTarget(commodity)
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set Target") {
                        if let value = Decimal(string: amount), value > 0 {
                            model.setPriceTarget(commodity, target: value, direction: direction)
                        }
                        dismiss()
                    }
                    .disabled(Decimal(string: amount).map { $0 <= 0 } ?? true)
                }
            }
            .onAppear {
                if let existing = model.priceTarget(for: commodity) {
                    amount = NSDecimalNumber(decimal: existing.target).stringValue
                    direction = existing.direction
                }
            }
        }
        .frame(minWidth: 380, minHeight: 260)
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

//
//  PricesView.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine

/// The price editor: list and add security prices (`FR-INV-02`).
struct PricesView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            Group {
                if model.priceRows.isEmpty {
                    ContentUnavailableView("No prices", systemImage: "tag",
                                           description: Text("Add prices for your securities to value the portfolio."))
                } else {
                    List {
                        ForEach(model.priceRows) { row in
                            HStack {
                                Text(row.symbol).fontWeight(.medium)
                                Text(row.date, format: .dateTime.year().month().day())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(AmountFormat.string(row.value, code: row.currencyCode))
                                    .monospacedDigit()
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { model.deletePrice(model.priceRows[index].id) }
                        }
                    }
                }
            }
            .navigationTitle("Prices")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem {
                    Button("Add Price", systemImage: "plus") { showingAdd = true }
                        .disabled(model.securityCommodities.isEmpty)
                }
            }
            .sheet(isPresented: $showingAdd) { AddPriceSheet(model: model) }
        }
        .frame(minWidth: 460, minHeight: 380)
    }
}

/// Adds a single price for a security.
struct AddPriceSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var commodityKey: String = ""
    @State private var date = Date()
    @State private var valueText = ""

    private var commodities: [Commodity] { model.securityCommodities }
    private func key(_ c: Commodity) -> String { "\(c.namespace)|\(c.mnemonic)" }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Security", selection: $commodityKey) {
                    Text("—").tag("")
                    ForEach(commodities, id: \.self) { Text($0.mnemonic).tag(key($0)) }
                }
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TextField("Price (\(model.reportCurrency.mnemonic))", text: $valueText)
                    .multilineTextAlignment(.trailing)
            }
            .navigationTitle("Add Price")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(commodityKey.isEmpty || Decimal(string: valueText) == nil)
                }
            }
        }
    }

    private func add() {
        guard let commodity = commodities.first(where: { key($0) == commodityKey }),
              let value = Decimal(string: valueText)
        else { return }
        model.addPrice(commodity: commodity, currency: model.reportCurrency, date: date, value: value)
        dismiss()
    }
}

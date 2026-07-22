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
    @Environment(\.appDateFormat) private var dateFormat
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isEmbeddedDestination) private var embedded
    @State private var showingAdd = false
    @State private var showingQuotes = false
    @State private var showingAddRate = false
    @State private var showingSecurities = false
    @State private var importingCSV = false
    @State private var importMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if model.priceRows.isEmpty && model.rateRows.isEmpty {
                    ContentUnavailableView("No prices", systemImage: "tag",
                                           description: Text("Add security prices or exchange rates to value the portfolio."))
                } else {
                    List {
                        if !model.priceRows.isEmpty {
                            Section("Security Prices") {
                                ForEach(model.priceRows) { row in
                                    HStack {
                                        Text(row.symbol).fontWeight(.medium)
                                        Text(dateFormat.string(row.date))
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
                        if !model.rateRows.isEmpty {
                            Section("Exchange Rates") {
                                ForEach(model.rateRows) { row in
                                    HStack {
                                        Text("\(row.from) → \(row.to)").fontWeight(.medium)
                                        Text(dateFormat.string(row.date))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text(row.value.formatted(.number.precision(.fractionLength(0...6))))
                                            .monospacedDigit()
                                    }
                                }
                                .onDelete { offsets in
                                    for index in offsets { model.deletePrice(model.rateRows[index].id) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Prices & Rates")
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                ToolbarItem {
                    Button("Securities", systemImage: "building.2") { showingSecurities = true }
                }
                ToolbarItem {
                    Button("Get Quotes", systemImage: "arrow.down.circle") { showingQuotes = true }
                        .disabled(model.pricableSecurities.isEmpty)
                }
                ToolbarItem {
                    Button("Add Rate", systemImage: "dollarsign.arrow.circlepath") { showingAddRate = true }
                        .disabled(model.currencyCommodities.count < 2)
                }
                ToolbarItem {
                    Button("Import CSV", systemImage: "square.and.arrow.down") { importingCSV = true }
                }
                ToolbarItem {
                    Button("Add Price", systemImage: "plus") { showingAdd = true }
                        .disabled(model.pricableSecurities.isEmpty)
                }
            }
            .sheet(isPresented: $showingAdd) { AddPriceSheet(model: model) }
            .sheet(isPresented: $showingQuotes) { QuotesView(model: model) }
            .sheet(isPresented: $showingAddRate) { AddRateSheet(model: model) }
            .sheet(isPresented: $showingSecurities) { SecuritiesView(model: model) }
            .fileImporter(isPresented: $importingCSV, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
                guard case let .success(url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    importMessage = "Couldn't read the file."; return
                }
                let outcome = model.importPrices(csv: text)
                if outcome.unrecognisedFormat {
                    importMessage = "Couldn't find Date / Commodity / Price columns in the CSV header."
                } else {
                    var msg = "Imported \(outcome.imported) price\(outcome.imported == 1 ? "" : "s")."
                    if !outcome.unmatchedSymbols.isEmpty {
                        msg += "\nSkipped unknown symbols: \(outcome.unmatchedSymbols.joined(separator: ", "))."
                    }
                    importMessage = msg
                }
            }
            .alert("Price Import", isPresented: Binding(
                get: { importMessage != nil }, set: { if !$0 { importMessage = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(importMessage ?? "") }
        }
        .frame(minWidth: embedded ? nil : 460, minHeight: embedded ? nil : 380)
    }
}

/// Adds a single price for a security.
struct AddPriceSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var commodityKey: String = ""
    @State private var date = Date()
    @State private var valueText = ""

    private var commodities: [Commodity] { model.pricableSecurities }
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
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
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

/// Adds a single exchange rate between two of the book's currencies.
struct AddRateSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var fromCode = ""
    @State private var toCode = ""
    @State private var date = Date()
    @State private var rateText = ""

    private var currencies: [Commodity] { model.currencyCommodities }

    var body: some View {
        NavigationStack {
            Form {
                Picker("From", selection: $fromCode) {
                    Text("—").tag("")
                    ForEach(currencies, id: \.mnemonic) { Text($0.mnemonic).tag($0.mnemonic) }
                }
                Picker("To", selection: $toCode) {
                    Text("—").tag("")
                    ForEach(currencies, id: \.mnemonic) { Text($0.mnemonic).tag($0.mnemonic) }
                }
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TextField("Rate (1 \(fromCode.isEmpty ? "from" : fromCode) = ? \(toCode.isEmpty ? "to" : toCode))",
                          text: $rateText)
                    .multilineTextAlignment(.trailing)
            }
            .navigationTitle("Add Exchange Rate")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }.disabled(!isValid)
                }
            }
        }
    }

    private var isValid: Bool {
        !fromCode.isEmpty && !toCode.isEmpty && fromCode != toCode && (Decimal(string: rateText) ?? 0) > 0
    }

    private func add() {
        guard let from = currencies.first(where: { $0.mnemonic == fromCode }),
              let to = currencies.first(where: { $0.mnemonic == toCode }),
              let rate = Decimal(string: rateText) else { return }
        model.addExchangeRate(from: from, to: to, rate: rate, date: date)
        dismiss()
    }
}

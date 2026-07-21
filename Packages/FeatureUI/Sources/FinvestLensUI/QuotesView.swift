//
//  QuotesView.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine
import FinvestLensQuotes

/// Configure quote providers (API keys), map securities to tickers, and fetch
/// latest/historical prices (`FR-INV-03`).
struct QuotesView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedProvider: QuoteProviderKind = .yahoo
    @State private var isFetching = false

    var body: some View {
        NavigationStack {
            Form {
                fetchSection
                keysHintSection
                securitiesSection
            }
            .formStyle(.grouped)
            .navigationTitle("Quotes")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: ensureValidProvider)
        }
        .frame(minWidth: 520, minHeight: 520)
    }

    // MARK: Fetch

    private var fetchSection: some View {
        Section("Fetch Prices") {
            Picker("Provider", selection: $selectedProvider) {
                ForEach(model.availableProviders) { Text($0.displayName).tag($0) }
            }
            Button {
                fetchLatest()
            } label: {
                if isFetching {
                    HStack { ProgressView().controlSize(.small); Text("Fetching…") }
                } else {
                    Label("Fetch Latest Prices", systemImage: "arrow.down.circle")
                }
            }
            .disabled(isFetching || model.pricableSecurities.isEmpty)

            Toggle("Auto-refresh on open (Yahoo, every 6h)", isOn: Binding(
                get: { model.autoRefreshQuotes },
                set: { model.autoRefreshQuotes = $0 }))

            statusRow
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch model.quoteStatus {
        case .idle:
            EmptyView()
        case .fetching(let what):
            Label("Fetching \(what)…", systemImage: "clock").foregroundStyle(.secondary)
        case .success(let count):
            Label("Added \(count) price\(count == 1 ? "" : "s").", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .scaledFont(.callout)
        }
    }

    // MARK: Keys (managed in Settings)

    private var keysHintSection: some View {
        Section {
            #if os(macOS)
            SettingsLink {
                Label("Manage API keys in Settings…", systemImage: "key")
            }
            #endif
        } footer: {
            Text("Price-provider API keys — EODHD, Alpha Vantage, Finnhub, Twelve Data — are managed in Settings ▸ Pricing (⌘,). Yahoo and Stooq need no key.")
        }
    }

    // MARK: Securities / ticker overrides

    private var securitiesSection: some View {
        Section {
            if model.pricableSecurities.isEmpty {
                Text("No securities held yet.").foregroundStyle(.secondary)
            } else {
                ForEach(model.pricableSecurities, id: \.self) { commodity in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(commodity.mnemonic).fontWeight(.medium)
                            Text(commodity.fullName).scaledFont(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        TextField(commodity.mnemonic, text: Binding(
                            get: { model.quoteSymbol(for: commodity) ?? "" },
                            set: { model.setQuoteSymbol($0, for: commodity) }))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 140)
                    }
                }
            }
        } header: {
            Text("Ticker Symbols")
        } footer: {
            Text("Override the ticker sent to the provider (e.g. CBA → CBA.AX for Yahoo).")
        }
    }

    // MARK: Actions

    private func ensureValidProvider() {
        if !model.availableProviders.contains(selectedProvider),
           let first = model.availableProviders.first {
            selectedProvider = first
        }
    }

    private func fetchLatest() {
        isFetching = true
        let provider = selectedProvider
        Task {
            await model.fetchLatestQuotes(using: provider)
            isFetching = false
        }
    }
}

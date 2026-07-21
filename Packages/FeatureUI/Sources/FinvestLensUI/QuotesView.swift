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
    @State private var selection: Set<Commodity> = []
    @State private var confirmRefetch = false

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
            .confirmationDialog(
                "Replace price history for \(selection.count) selected securit\(selection.count == 1 ? "y" : "ies")?",
                isPresented: $confirmRefetch, titleVisibility: .visible
            ) {
                Button("Replace History", role: .destructive) { refetchSelected() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Existing prices for the selected securities are replaced with a freshly fetched series. If a fetch fails, that security keeps its current prices.")
            }
        }
        .frame(minWidth: 520, minHeight: 560)
    }

    // MARK: Fetch

    private var fetchSection: some View {
        Section {
            Picker("Provider", selection: $selectedProvider) {
                ForEach(model.availableProviders) { Text($0.displayName).tag($0) }
            }
            Button {
                updatePrices()
            } label: {
                if isFetching {
                    HStack { ProgressView().controlSize(.small); Text("Fetching…") }
                } else {
                    Label("Update Prices to Today", systemImage: "arrow.down.circle")
                }
            }
            .disabled(isFetching || model.pricableSecurities.isEmpty)

            Toggle("Auto-refresh on open (Yahoo, every 6h)", isOn: Binding(
                get: { model.autoRefreshQuotes },
                set: { model.autoRefreshQuotes = $0 }))

            progressRow
            statusRow
        } header: {
            Text("Fetch Prices")
        } footer: {
            Text("Fills each security's history — including any gaps between existing prices — from its first holding through today, so every holding is current when the fetch finishes.")
        }
    }

    /// A determinate bar shown while a multi-security fetch runs.
    @ViewBuilder
    private var progressRow: some View {
        if let progress = model.quoteProgress {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress)
                if case .fetching(let what) = model.quoteStatus {
                    Text("Fetching \(what)…")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch model.quoteStatus {
        case .idle:
            EmptyView()
        case .fetching(let what):
            // While a determinate fetch runs, the progress bar shows this instead.
            if model.quoteProgress == nil {
                Label("Fetching \(what)…", systemImage: "clock").foregroundStyle(.secondary)
            }
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
                    securityRow(commodity)
                }
            }
        } header: {
            HStack {
                Text("Ticker Symbols")
                Spacer()
                if !model.pricableSecurities.isEmpty {
                    Button(selection.isEmpty ? "Select All" : "Clear") {
                        selection = selection.isEmpty ? Set(model.pricableSecurities) : []
                    }
                    .buttonStyle(.borderless)
                    .scaledFont(.caption)
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    confirmRefetch = true
                } label: {
                    Label("Refetch Selected (Replace History)", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isFetching || selection.isEmpty)

                Text("Select securities above, then refetch to rebuild their price history from scratch. Override the ticker sent to the provider (e.g. CBA → CBA.AX for Yahoo).")
            }
        }
    }

    private func securityRow(_ commodity: Commodity) -> some View {
        let isSelected = selection.contains(commodity)
        return HStack(spacing: 10) {
            Button {
                if isSelected { selection.remove(commodity) } else { selection.insert(commodity) }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelected ? "Deselect \(commodity.mnemonic)" : "Select \(commodity.mnemonic)")

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

    // MARK: Actions

    private func ensureValidProvider() {
        if !model.availableProviders.contains(selectedProvider),
           let first = model.availableProviders.first {
            selectedProvider = first
        }
    }

    private func updatePrices() {
        isFetching = true
        let provider = selectedProvider
        Task {
            await model.updatePriceHistory(using: provider)
            isFetching = false
        }
    }

    private func refetchSelected() {
        isFetching = true
        let provider = selectedProvider
        let commodities = model.pricableSecurities.filter { selection.contains($0) }
        Task {
            await model.refetchPriceHistory(for: commodities, using: provider)
            isFetching = false
        }
    }
}

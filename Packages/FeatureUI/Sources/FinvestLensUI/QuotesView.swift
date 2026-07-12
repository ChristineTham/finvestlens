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
    @State private var keyDrafts: [QuoteProviderKind: String] = [:]
    @State private var isFetching = false

    var body: some View {
        NavigationStack {
            Form {
                fetchSection
                providersSection
                securitiesSection
            }
            .formStyle(.grouped)
            .navigationTitle("Quotes")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: loadDrafts)
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
            .disabled(isFetching || model.securityCommodities.isEmpty)

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
                .font(.callout)
        }
    }

    // MARK: Providers / API keys

    private var providersSection: some View {
        Section("Providers") {
            ForEach(QuoteProviderKind.allCases) { kind in
                if kind.requiresAPIKey {
                    keyRow(for: kind)
                } else {
                    LabeledContent(kind.displayName) {
                        Text("No key required").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func keyRow(for kind: QuoteProviderKind) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(kind.displayName)
                if model.apiKey(for: kind)?.isEmpty == false {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                }
                Spacer()
                if let url = kind.signupURL {
                    Link("Get key", destination: url).font(.caption)
                }
            }
            HStack {
                SecureField("API key", text: Binding(
                    get: { keyDrafts[kind] ?? "" },
                    set: { keyDrafts[kind] = $0 }))
                Button("Save") {
                    model.setAPIKey(keyDrafts[kind], for: kind)
                }
                .disabled((keyDrafts[kind] ?? "") == (model.apiKey(for: kind) ?? ""))
                if model.apiKey(for: kind)?.isEmpty == false {
                    Button("Clear", role: .destructive) {
                        model.setAPIKey(nil, for: kind)
                        keyDrafts[kind] = ""
                    }
                }
            }
        }
    }

    // MARK: Securities / ticker overrides

    private var securitiesSection: some View {
        Section {
            if model.securityCommodities.isEmpty {
                Text("No securities held yet.").foregroundStyle(.secondary)
            } else {
                ForEach(model.securityCommodities, id: \.self) { commodity in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(commodity.mnemonic).fontWeight(.medium)
                            Text(commodity.fullName).font(.caption).foregroundStyle(.secondary)
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

    private func loadDrafts() {
        for kind in QuoteProviderKind.allCases where kind.requiresAPIKey {
            keyDrafts[kind] = model.apiKey(for: kind) ?? ""
        }
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

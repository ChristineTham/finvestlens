//
//  ImportView.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine
import FinvestLensInterchange

/// A file the user chose to import, with its detected format.
struct ImportPayload: Identifiable {
    let id = UUID()
    let data: Data
    let format: BankFileFormat
}

/// Reviews a bank file before import: pick the target account, preview matched
/// rows (with duplicate flags and suggested destinations), then post
/// (`FR-XIO-03/05`).
struct ImportView: View {
    @Bindable var model: AppModel
    let payload: ImportPayload
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFontScale) private var appFontScale
    private var dateWidth: CGFloat { 96 * appFontScale }

    @State private var targetID: GncGUID?
    @State private var results: [MatchResult] = []
    @State private var assignments: [UUID: GncGUID] = [:]
    @State private var skipDuplicates = true

    // CSV column mapping (only shown for CSV).
    @State private var dateCol = 0
    @State private var amountCol = 1
    @State private var payeeCol = 2
    @State private var dateFormat = "yyyy-MM-dd"
    @State private var hasHeader = true

    private var accounts: [AccountNode] { model.postableAccounts }
    private var importCount: Int {
        results.filter { !(skipDuplicates && $0.isDuplicate) && destination(for: $0) != nil }.count
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Import into") {
                    Picker("Account", selection: $targetID) {
                        Text("—").tag(GncGUID?.none)
                        ForEach(accounts) { Text($0.fullName).tag(GncGUID?.some($0.id)) }
                    }
                }

                if payload.format == .csv {
                    Section("CSV columns (0-based)") {
                        Stepper("Date column: \(dateCol)", value: $dateCol, in: 0...20)
                        Stepper("Amount column: \(amountCol)", value: $amountCol, in: 0...20)
                        Stepper("Payee column: \(payeeCol)", value: $payeeCol, in: 0...20)
                        TextField("Date format", text: $dateFormat)
                        Toggle("Has header row", isOn: $hasHeader)
                    }
                }

                Section {
                    Button("Preview") { preview() }
                        .disabled(targetID == nil)
                }

                if !results.isEmpty {
                    Toggle("Skip duplicates", isOn: $skipDuplicates)
                    Section("\(results.count) transactions") {
                        ForEach(results) { result in
                            row(result)
                        }
                    }
                }
            }
            .navigationTitle("Import \(payload.format.rawValue.uppercased())")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import \(importCount)") {
                        if let targetID {
                            _ = model.importMatched(results, intoAccountID: targetID,
                                                    assignments: assignments,
                                                    skipDuplicates: skipDuplicates)
                        }
                        dismiss()
                    }
                    .disabled(importCount == 0)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 520)
    }

    // MARK: Row

    @ViewBuilder
    private func row(_ result: MatchResult) -> some View {
        let staged = result.staged
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(staged.date, format: .dateTime.year().month().day())
                    .foregroundStyle(.secondary)
                    .frame(width: dateWidth, alignment: .leading)
                Text(staged.payee.isEmpty ? staged.memo : staged.payee)
                if result.isDuplicate {
                    Text("duplicate").scaledFont(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.yellow.opacity(0.3), in: Capsule())
                }
                Spacer()
                Text(AmountFormat.string(staged.amount, code: targetCode))
                    .monospacedDigit()
                    .foregroundStyle(staged.amount < 0 ? .red : .primary)
            }
            Picker("Destination", selection: destinationBinding(for: result)) {
                Text("— none —").tag(GncGUID?.none)
                ForEach(accounts.filter { $0.id != targetID }) {
                    Text($0.fullName).tag(GncGUID?.some($0.id))
                }
            }
            .labelsHidden()
            .disabled(skipDuplicates && result.isDuplicate)
        }
    }

    private var targetCode: String {
        accounts.first { $0.id == targetID }?.currencyCode ?? "AUD"
    }

    private func destination(for result: MatchResult) -> GncGUID? {
        assignments[result.staged.id] ?? result.suggestedAccountID
    }

    private func destinationBinding(for result: MatchResult) -> Binding<GncGUID?> {
        Binding(
            get: { destination(for: result) },
            set: { assignments[result.staged.id] = $0 }
        )
    }

    private func preview() {
        guard let targetID else { return }
        let mapping = CSVColumnMapping(date: dateCol, amount: amountCol, payee: payeeCol,
                                       dateFormat: dateFormat, hasHeader: hasHeader)
        let staged = model.parseBankFile(payload.data, format: payload.format, csvMapping: mapping)
        results = model.matchStaged(staged, intoAccountID: targetID)
        assignments = [:]
    }
}

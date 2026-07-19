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

/// A file the user chose to import, with its detected format. PDF statements
/// arrive with `prestaged` rows already extracted by Apple Intelligence.
struct ImportPayload: Identifiable {
    let id = UUID()
    let data: Data
    let format: BankFileFormat
    var prestaged: [StagedTransaction]?

    init(data: Data, format: BankFileFormat, prestaged: [StagedTransaction]? = nil) {
        self.data = data
        self.format = format
        self.prestaged = prestaged
    }
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
    @State private var markMatchedCleared = true
    @State private var suggesting = false
    @State private var suggestError: String?

    // CSV column mapping (only shown for CSV).
    @State private var dateCol = 0
    @State private var amountCol = 1
    @State private var payeeCol = 2
    @State private var dateFormat = "yyyy-MM-dd"
    @State private var hasHeader = true
    @State private var showingSaveProfile = false
    @State private var newProfileName = ""

    // Investment (security) rows — imported via the Stock Assistant path.
    @State private var investments: [StagedTransaction] = []
    @State private var invSecurity: [UUID: GncGUID] = [:]
    @State private var invSettlement: GncGUID?
    @State private var invIncome: GncGUID?
    @State private var invError: String?
    @State private var invCreated = 0

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
                        if !model.csvImportProfiles.isEmpty {
                            Menu("Load Profile") {
                                ForEach(model.csvImportProfiles) { profile in
                                    Button(profile.name) { applyProfile(profile) }
                                }
                                Divider()
                                ForEach(model.csvImportProfiles) { profile in
                                    Button(role: .destructive) {
                                        model.deleteCSVImportProfile(profile.id)
                                    } label: { Label("Delete “\(profile.name)”", systemImage: "trash") }
                                }
                            }
                        }
                        Stepper("Date column: \(dateCol)", value: $dateCol, in: 0...20)
                        Stepper("Amount column: \(amountCol)", value: $amountCol, in: 0...20)
                        Stepper("Payee column: \(payeeCol)", value: $payeeCol, in: 0...20)
                        TextField("Date format", text: $dateFormat)
                        Toggle("Has header row", isOn: $hasHeader)
                        Button("Save as Profile…") { newProfileName = ""; showingSaveProfile = true }
                    }
                }

                Section {
                    Button("Preview") { preview() }
                        .disabled(targetID == nil)
                }

                if !results.isEmpty {
                    Toggle("Skip duplicates", isOn: $skipDuplicates)
                    if results.contains(where: \.isDuplicate) {
                        Toggle("Mark matched transactions as cleared", isOn: $markMatchedCleared)
                            .help("Reconcile register entries that this statement confirms")
                    }
                    if model.isIntelligenceAvailable {
                        Section {
                            Button {
                                suggestCategories()
                            } label: {
                                Label(suggesting ? "Suggesting…" : "Suggest Categories",
                                      systemImage: "sparkles")
                            }
                            .disabled(suggesting)
                            .help("Let Apple Intelligence propose a destination account for each row")
                            if let suggestError {
                                Text(suggestError).scaledFont(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                    Section("\(results.count) transactions") {
                        ForEach(results) { result in
                            row(result)
                        }
                    }
                }

                if !investments.isEmpty {
                    investmentSection
                }
            }
            .navigationTitle("Import \(payload.format.rawValue.uppercased())")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import \(importCount)") {
                        if let targetID {
                            _ = model.importMatched(results, intoAccountID: targetID,
                                                    assignments: assignments,
                                                    skipDuplicates: skipDuplicates)
                            if markMatchedCleared {
                                model.reconcileMatchedDuplicates(results)
                            }
                        }
                        dismiss()
                    }
                    .disabled(importCount == 0 && !(markMatchedCleared && results.contains(where: \.isDuplicate)))
                }
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .alert("Save Import Profile", isPresented: $showingSaveProfile) {
            TextField("Profile name", text: $newProfileName)
            Button("Save") {
                let name = newProfileName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                model.saveCSVImportProfile(CSVImportProfile(
                    name: name, dateColumn: dateCol, amountColumn: amountCol,
                    payeeColumn: payeeCol, dateFormat: dateFormat, hasHeader: hasHeader))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Save these column settings to reuse on the next import from this bank.")
        }
    }

    private func applyProfile(_ profile: CSVImportProfile) {
        dateCol = profile.dateColumn
        amountCol = profile.amountColumn
        payeeCol = profile.payeeColumn
        dateFormat = profile.dateFormat
        hasHeader = profile.hasHeader
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
        let staged = payload.prestaged
            ?? model.parseBankFile(payload.data, format: payload.format, csvMapping: mapping)
        results = model.matchStaged(staged, intoAccountID: targetID)
        assignments = [:]

        // Security rows take the Stock-Assistant path, pre-matching each to a
        // security account by name/ticker where one exists.
        investments = model.investmentRows(from: staged)
        invSecurity = [:]
        for row in investments {
            invSecurity[row.id] = model.matchingSecurityAccount(for: row)
        }
        invSettlement = targetID
        invCreated = 0
    }

    // MARK: Investment rows (FR-XIO-01/02)

    private var securityAccounts: [AccountNode] { model.securityAccountNodes }
    private var incomeAccounts: [AccountNode] { model.incomeAccountNodes }
    private var creatableInvestments: [StagedTransaction] {
        investments.filter { row in
            guard let inv = row.investment else { return false }
            let hasSecurity = invSecurity[row.id] != nil
            let hasIncome = invIncome != nil
            switch inv.action {
            case .buy, .sell: return hasSecurity && invSettlement != nil
            case .dividend: return hasIncome && invSettlement != nil
            case .reinvestDividend: return hasSecurity && hasIncome
            case .other: return false
            }
        }
    }

    @ViewBuilder
    private var investmentSection: some View {
        Section("\(investments.count) investment transactions") {
            Picker("Settlement account", selection: $invSettlement) {
                Text("—").tag(GncGUID?.none)
                ForEach(model.settlementAccountNodes) { Text($0.fullName).tag(GncGUID?.some($0.id)) }
            }
            Picker("Dividend income account", selection: $invIncome) {
                Text("—").tag(GncGUID?.none)
                ForEach(incomeAccounts) { Text($0.fullName).tag(GncGUID?.some($0.id)) }
            }
            ForEach(investments) { row in
                investmentRow(row)
            }
            if let invError {
                Text(invError).scaledFont(.caption).foregroundStyle(.red)
            }
            if invCreated > 0 {
                Label("Created \(invCreated) investment transaction\(invCreated == 1 ? "" : "s").",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).scaledFont(.caption)
            }
            Button("Create \(creatableInvestments.count) Investment Transactions") {
                createInvestments()
            }
            .disabled(creatableInvestments.isEmpty)
        }
    }

    @ViewBuilder
    private func investmentRow(_ row: StagedTransaction) -> some View {
        let inv = row.investment
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.date, format: .dateTime.year().month().day())
                    .foregroundStyle(.secondary).frame(width: dateWidth, alignment: .leading)
                Text(inv?.action.rawValue.capitalized ?? "—").fontWeight(.medium)
                Text(inv?.security ?? "").foregroundStyle(.secondary)
                Spacer()
                Text(AmountFormat.string(row.amount, code: targetCode)).monospacedDigit()
            }
            if let inv, inv.quantity != 0 {
                Text("\(inv.quantity.formatted()) @ \(AmountFormat.string(inv.pricePerShare, code: targetCode))"
                     + (inv.commission != 0 ? " · fee \(AmountFormat.string(inv.commission, code: targetCode))" : ""))
                    .scaledFont(.caption).foregroundStyle(.secondary)
            }
            if inv?.action != .dividend {
                Picker("Security", selection: Binding(
                    get: { invSecurity[row.id] },
                    set: { invSecurity[row.id] = $0 })) {
                    Text("Choose security…").tag(GncGUID?.none)
                    ForEach(securityAccounts) { Text($0.fullName).tag(GncGUID?.some($0.id)) }
                }
                .scaledFont(.caption)
            }
        }
    }

    private func createInvestments() {
        invError = nil
        // Track exactly which rows were posted so a mid-batch failure can't leave
        // an already-created row in the list — re-clicking would post it twice.
        var createdIDs: [UUID] = []
        for row in investments {
            guard creatableInvestments.contains(where: { $0.id == row.id }) else { continue }
            do {
                if try model.recordStagedInvestment(
                    row, securityID: invSecurity[row.id], settlementID: invSettlement,
                    incomeID: invIncome) != nil {
                    createdIDs.append(row.id)
                }
            } catch {
                invError = "Couldn't create “\(row.investment?.security ?? "")”: \(error.localizedDescription)"
            }
        }
        invCreated = createdIDs.count
        // Drop the ones that were actually created (even if a later row failed) so
        // the list reflects what's left and nothing is posted a second time.
        let done = Set(createdIDs)
        investments.removeAll { done.contains($0.id) }
    }

    /// Fills empty destinations with on-device model suggestions (`FR-AI-02`).
    /// Deterministic suggestions (rules/history/heuristics) are never replaced.
    private func suggestCategories() {
        suggesting = true
        suggestError = nil
        let pending = results
        Task {
            defer { suggesting = false }
            do {
                let suggested = try await model.suggestCategories(for: pending)
                for (stagedID, accountID) in suggested where destinationForStagedID(stagedID) == nil {
                    assignments[stagedID] = accountID
                }
            } catch {
                suggestError = error.localizedDescription
            }
        }
    }

    private func destinationForStagedID(_ id: UUID) -> GncGUID? {
        guard let result = results.first(where: { $0.staged.id == id }) else { return nil }
        return destination(for: result)
    }
}

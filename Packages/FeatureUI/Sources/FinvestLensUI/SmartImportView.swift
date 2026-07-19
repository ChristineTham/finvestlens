//
//  SmartImportView.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Smart Import hub (`FR-AI-07`): drop several PDFs at once; each is
//  classified on-device and routed — statements to the import/reconcile
//  review, dividend statements to verification against the register,
//  invoices to split/re-date proposals. Every mutation still goes through
//  a review step.
//

import SwiftUI
import TipKit
import FinvestLensEngine
import FinvestLensInterchange
import FinvestLensIntelligence

/// The batch of PDFs picked for Smart Import.
struct SmartImportPayload: Identifiable {
    let id = UUID()
    var files: [(name: String, data: Data)]
}

/// One document making its way through classification → analysis → action.
private struct SmartDocument: Identifiable {
    enum Phase {
        case analyzing
        case statement([StagedTransaction])
        case dividend(DividendStatementDetails, AppModel.DividendCheckResult)
        case invoice(InvoiceAnalysis, AppModel.InvoiceMatch?)
        case unknown
        case failed(String)
        case done(String)
    }

    let id = UUID()
    let name: String
    let data: Data
    var kind: FinancialDocumentKind?
    var phase: Phase = .analyzing
}

struct SmartImportSheet: View {
    @Bindable var model: AppModel
    let payload: SmartImportPayload
    @Environment(\.dismiss) private var dismiss

    @State private var documents: [SmartDocument] = []
    @State private var started = false
    // Child review sheets (statement import, unmatched dividend recording).
    @State private var importPayload: ImportPayload?
    @State private var dividendPayload: DividendPayload?
    @State private var activeDocumentID: UUID?

    var body: some View {
        NavigationStack {
            Group {
                if documents.isEmpty {
                    ProgressView("Reading documents…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Form {
                        TipView(SmartImportTip())
                        ForEach($documents) { $document in
                            Section {
                                SmartDocumentRow(model: model, document: $document,
                                                 onReviewStatement: { reviewStatement($document.wrappedValue) },
                                                 onRecordDividend: { recordDividend($document.wrappedValue) },
                                                 onRegisterChanged: { refreshMatches() })
                            }
                        }
                    }
                    .formStyle(.grouped)
                }
            }
            .navigationTitle("Smart Import")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await analyzeAll() }
            .sheet(item: $importPayload, onDismiss: { markActiveDone("Reviewed") }) { payload in
                ImportView(model: model, payload: payload)
            }
            .background {
                Color.clear
                    .sheet(item: $dividendPayload, onDismiss: { markActiveDone("Reviewed") }) { payload in
                        DividendImportSheet(model: model, payload: payload)
                    }
            }
        }
        .frame(minWidth: 700, minHeight: 520)
    }

    // MARK: Analysis

    private func analyzeAll() async {
        guard !started else { return }
        started = true
        documents = payload.files.map { SmartDocument(name: $0.name, data: $0.data) }
        for index in documents.indices {
            await analyze(at: index)
        }
    }

    private func analyze(at index: Int) async {
        let data = documents[index].data
        do {
            let text = try await Task.detached { try await DocumentText.extractText(from: data) }.value
            let kind = await DocumentClassifier.classify(text: text)
            documents[index].kind = kind
            switch kind {
            case .bankStatement:
                let staged = try await model.extractStatementPDF(data)
                documents[index].phase = .statement(staged)
            case .dividendStatement:
                let details = try await model.extractDividendStatement(data)
                documents[index].phase = .dividend(details, model.checkDividendStatement(details))
            case .invoice:
                let analysis = try await model.analyzeInvoicePDF(data)
                documents[index].phase = .invoice(analysis, model.findInvoiceMatch(for: analysis))
            case .unknown:
                documents[index].phase = .unknown
            }
        } catch {
            documents[index].phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Actions

    private func reviewStatement(_ document: SmartDocument) {
        guard case .statement(let staged) = document.phase else { return }
        activeDocumentID = document.id
        importPayload = ImportPayload(data: document.data, format: .pdf, prestaged: staged)
    }

    private func recordDividend(_ document: SmartDocument) {
        guard case .dividend(let details, _) = document.phase else { return }
        activeDocumentID = document.id
        dividendPayload = DividendPayload(data: document.data, prefilled: details,
                                          fileName: document.name)
    }

    private func markActiveDone(_ note: String) {
        guard let id = activeDocumentID,
              let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].phase = .done(note)
        activeDocumentID = nil
        refreshMatches()
    }

    /// Re-checks dividend and invoice documents against the register — an
    /// imported statement (or an applied fix) can turn a "no match" into a
    /// match without re-running the model.
    private func refreshMatches() {
        for index in documents.indices {
            switch documents[index].phase {
            case .dividend(let details, _):
                documents[index].phase = .dividend(details, model.checkDividendStatement(details))
            case .invoice(let analysis, _):
                documents[index].phase = .invoice(analysis, model.findInvoiceMatch(for: analysis))
            default:
                break
            }
        }
    }
}

// MARK: - Row

private struct SmartDocumentRow: View {
    @Bindable var model: AppModel
    @Binding var document: SmartDocument
    var onReviewStatement: () -> Void
    var onRecordDividend: () -> Void
    var onRegisterChanged: () -> Void

    @State private var adjustDate = true
    @State private var actionError: String?
    /// Set when the user chooses to create a transaction for an unmatched
    /// invoice (`FR-AI-07`); presents the funding-account picker.
    @State private var creatingInvoice: IdentifiedInvoice?

    /// Wraps a non-Identifiable ``InvoiceAnalysis`` for `.sheet(item:)`.
    private struct IdentifiedInvoice: Identifiable {
        let id = UUID()
        let analysis: InvoiceAnalysis
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(document.name).fontWeight(.medium)
                    Text(document.kind?.displayName ?? "Identifying…")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                trailing
            }
            detail
            if let actionError {
                Text(actionError).scaledFont(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
        .sheet(item: $creatingInvoice) { wrapper in
            CreateFromInvoiceSheet(model: model, analysis: wrapper.analysis) { txnID in
                document.phase = .done(linkNote("Transaction created", attachTo: txnID))
                onRegisterChanged()
            }
        }
    }

    private var icon: String {
        switch document.kind {
        case .bankStatement: return "building.columns"
        case .dividendStatement: return "banknote"
        case .invoice: return "doc.text"
        case .unknown: return "questionmark.folder"
        case nil: return "doc.viewfinder"
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch document.phase {
        case .analyzing:
            ProgressView().controlSize(.small)
        case .done(let note):
            Label(note, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).scaledFont(.caption)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch document.phase {
        case .analyzing, .done:
            EmptyView()

        case .failed(let message):
            Text(message).scaledFont(.caption).foregroundStyle(.red)

        case .unknown:
            Text("Couldn’t identify this document — import it manually if needed.")
                .scaledFont(.caption).foregroundStyle(.secondary)

        case .statement(let staged):
            HStack {
                Text("\(staged.count) transactions found — review to import and reconcile.")
                    .scaledFont(.callout)
                Spacer()
                Button("Review & Import…") { onReviewStatement() }
            }

        case .dividend(let details, let check):
            dividendDetail(details, check)

        case .invoice(let analysis, let match):
            invoiceDetail(analysis, match)
        }
    }

    @ViewBuilder
    private func dividendDetail(_ details: DividendStatementDetails,
                                _ check: AppModel.DividendCheckResult) -> some View {
        let code = model.reportCurrency.mnemonic
        VStack(alignment: .leading, spacing: 4) {
            Text("\(details.securityName.isEmpty ? details.ticker : details.securityName): net \(AmountFormat.string(details.netPayment, code: code)), franking credits \(AmountFormat.string(details.frankingCredits, code: code))")
                .scaledFont(.callout)
            switch check.verdict {
            case .verified:
                Label("Matches “\(check.transactionDescription)” — franking credits verified.",
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green).scaledFont(.callout)
            case .missingFrankingCredits:
                Label("Matches “\(check.transactionDescription)” but only \(AmountFormat.string(check.foundFrankingCredits, code: code)) of \(AmountFormat.string(details.frankingCredits, code: code)) franking credits are booked.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).scaledFont(.callout)
                Button("Fix Transaction") { fixDividend(details, check) }
                    .disabled(!details.componentsMatchPayment)
            case .noMatch:
                Text("No matching deposit in the register.")
                    .scaledFont(.callout).foregroundStyle(.secondary)
                Button("Record Dividend…") { onRecordDividend() }
            }
        }
    }

    @ViewBuilder
    private func invoiceDetail(_ analysis: InvoiceAnalysis,
                               _ match: AppModel.InvoiceMatch?) -> some View {
        let code = model.reportCurrency.mnemonic
        VStack(alignment: .leading, spacing: 4) {
            Text("\(analysis.vendor): \(analysis.lineItems.count) items, total \(AmountFormat.string(analysis.total, code: code))")
                .scaledFont(.callout)
            ForEach(analysis.lineItems) { item in
                HStack {
                    Text("•  \(item.itemDescription)")
                    Text(categoryName(item.suggestedCategoryID))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(AmountFormat.string(item.amount, code: code)).monospacedDigit()
                }
                .scaledFont(.caption)
            }
            if analysis.lineItemSum != analysis.total {
                Text("Line items differ from the total by \(AmountFormat.string(analysis.total - analysis.lineItemSum, code: code)) — an adjustment split will be added.")
                    .scaledFont(.caption).foregroundStyle(.orange)
            }
            if let match {
                Label("Matches “\(match.transactionDescription)” of \(match.datePosted.formatted(date: .abbreviated, time: .omitted)) from \(match.fundingAccountName).",
                      systemImage: "link")
                    .scaledFont(.callout)
                if let proposed = match.proposedDate {
                    Toggle("Set date to invoice date (\(proposed.formatted(date: .abbreviated, time: .omitted))) — the bank’s date is kept for matching",
                           isOn: $adjustDate)
                        .scaledFont(.caption)
                }
                Button("Apply Split") { applyInvoice(analysis, match) }
            } else {
                Text("No matching transaction in the register — import the bank statement, or create one now.")
                    .scaledFont(.callout).foregroundStyle(.secondary)
                Button("Create Transaction…") {
                    creatingInvoice = IdentifiedInvoice(analysis: analysis)
                }
            }
        }
    }

    private func categoryName(_ id: GncGUID?) -> String {
        guard let id, let node = model.postableAccounts.first(where: { $0.id == id }) else {
            return "→ previous category"
        }
        return "→ \(node.fullName)"
    }

    private func fixDividend(_ details: DividendStatementDetails,
                             _ check: AppModel.DividendCheckResult) {
        guard let id = check.transactionID else { return }
        do {
            try model.applyDividendFix(details, to: id)
            document.phase = .done(linkNote("Fixed", attachTo: id))
            onRegisterChanged()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func applyInvoice(_ analysis: InvoiceAnalysis, _ match: AppModel.InvoiceMatch) {
        do {
            try model.applyInvoiceSplit(analysis, to: match.transactionID, adjustDate: adjustDate)
            document.phase = .done(linkNote("Split applied", attachTo: match.transactionID))
            onRegisterChanged()
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Stores the PDF in the document folder and links it to the transaction
    /// (`FR-AI-08`). Linking is auxiliary — a failure never rolls back the
    /// applied change, it just shows in the row note.
    private func linkNote(_ note: String, attachTo transactionID: GncGUID) -> String {
        do {
            _ = try model.attachDocument(named: document.name, data: document.data,
                                         to: transactionID)
            return "\(note) · linked"
        } catch {
            actionError = error.localizedDescription
            return note
        }
    }
}

/// Picks a funding account and creates a transaction from an unmatched invoice
/// (`FR-AI-07`).
private struct CreateFromInvoiceSheet: View {
    @Bindable var model: AppModel
    let analysis: InvoiceAnalysis
    var onCreated: (GncGUID) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var fundingID: GncGUID?
    @State private var error: String?

    private var code: String { model.reportCurrency.mnemonic }
    private var fundingAccounts: [AccountNode] {
        model.postableAccounts.filter {
            $0.typeName == AccountType.bank.rawValue
                || $0.typeName == AccountType.cash.rawValue
                || $0.typeName == AccountType.asset.rawValue
                || $0.typeName == AccountType.credit.rawValue
                || $0.typeName == AccountType.liability.rawValue
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Vendor", value: analysis.vendor.isEmpty ? "—" : analysis.vendor)
                    LabeledContent("Total", value: AmountFormat.string(analysis.total, code: code))
                    if let date = analysis.date {
                        LabeledContent("Date", value: date.formatted(date: .abbreviated, time: .omitted))
                    }
                }
                Section("Pay from") {
                    Picker("Account", selection: $fundingID) {
                        Text("Choose…").tag(GncGUID?.none)
                        ForEach(fundingAccounts) { Text($0.fullName).tag(GncGUID?.some($0.id)) }
                    }
                    .labelsHidden()
                }
                Text("A transaction is created with the funding account paying the total, split across each line item's category.")
                    .scaledFont(.caption).foregroundStyle(.secondary)
                if let error {
                    Text(error).scaledFont(.caption).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Create Transaction")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }.disabled(fundingID == nil)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 320)
    }

    private func create() {
        guard let fundingID else { return }
        do {
            let txnID = try model.createTransactionFromInvoice(analysis, fundingAccountID: fundingID)
            dismiss()
            onCreated(txnID)
        } catch {
            self.error = "Couldn't create the transaction — check that line items have categories."
        }
    }
}

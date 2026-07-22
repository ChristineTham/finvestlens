//
//  CheckPrinting.swift
//  FinvestLens — FeatureUI
//
//  Printing a check for a transaction (`FR-REG-11`, GnuCash's Tools ▸ Print
//  Check). A check is drawn on a bank/asset account: the outflow split names the
//  amount, the transaction's description is the payee, and the amount is spelled
//  out on the legal line (``AmountInWords``). The layout follows the conventional
//  US personal-check positions GnuCash's default "Quicken/QuickBooks" format
//  prints — date and numeric amount at the right, payee and legal line at the
//  left, memo and signature at the foot.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine

/// Everything a printed check needs, derived from a transaction.
struct CheckData: Sendable {
    var payee: String
    var amount: Decimal
    var amountInWords: String
    var date: Date
    var memo: String
    var checkNumber: String
    var drawnOn: String
    var code: String
}

@MainActor
extension AppModel {

    /// The check for `txnID`, or `nil` when the book is closed, the transaction
    /// is gone, or it has no outflow from a bank/cash/asset account to draw on.
    /// The outflow (most-negative such split) sets the amount and the account it
    /// is drawn on; the transaction description is the payee.
    func checkData(forTransaction txnID: GncGUID) -> CheckData? {
        guard let book, let txn = book.transaction(with: txnID) else { return nil }
        let drawable: Set<AccountType> = [.bank, .cash, .asset]
        let outflow = txn.splits
            .filter { ($0.account.map { drawable.contains($0.type) } ?? false) && $0.value < 0 }
            .min { $0.value < $1.value }         // most negative
        guard let outflow, let account = outflow.account else { return nil }
        let amount = -outflow.value
        let payee = txn.transactionDescription.isEmpty
            ? (txn.splits.first { $0.value > 0 }?.account?.name ?? "")
            : txn.transactionDescription
        let memo = !txn.notes.isEmpty ? txn.notes : outflow.memo
        return CheckData(
            payee: payee,
            amount: amount,
            amountInWords: AmountInWords.english(amount, fraction: account.commodity.smallestFraction),
            date: txn.datePosted,
            memo: memo,
            checkNumber: txn.number,
            drawnOn: account.name,
            code: account.commodity.mnemonic)
    }
}

/// A static, print-ready check for `ImageRenderer` (VStack, not List).
struct PrintableCheck: View {
    let check: CheckData

    private func money(_ d: Decimal) -> String { AmountFormat.string(d, code: check.code) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            // Top line: drawn-on account (left) and date + number (right).
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(check.drawnOn).font(.headline)
                    if !check.checkNumber.isEmpty {
                        Text("No. \(check.checkNumber)").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                labelled("Date", AppDateFormat.current.short(check.date))
            }

            // Pay to the order of … numeric amount in a box.
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pay to the order of").font(.caption).foregroundStyle(.secondary)
                    Text(check.payee.isEmpty ? " " : check.payee)
                        .font(.title3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(.secondary), alignment: .bottom)
                }
                Text("\(money(check.amount))")
                    .font(.title3.monospacedDigit().bold())
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .overlay(Rectangle().strokeBorder(.secondary, lineWidth: 0.5))
            }

            // Legal line: the amount spelled out.
            Text(check.amountInWords + " dollars")
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(Rectangle().frame(height: 0.5).foregroundStyle(.secondary), alignment: .bottom)

            // Foot: memo (left) and signature line (right).
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Memo").font(.caption).foregroundStyle(.secondary)
                    Text(check.memo.isEmpty ? " " : check.memo).font(.callout)
                }
                .frame(width: 220, alignment: .leading)
                Spacer()
                VStack(spacing: 2) {
                    Text(" ").frame(width: 200)
                        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(.secondary), alignment: .bottom)
                    Text("Authorised signature").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(28)
        .frame(width: 620)
        .foregroundStyle(.black)
    }

    private func labelled(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).monospacedDigit()
        }
    }
}

/// Previews the check for a transaction and saves it as a PDF (`FR-REG-11`).
struct CheckPrintSheet: View {
    @Bindable var model: AppModel
    let txnID: GncGUID
    @Environment(\.dismiss) private var dismiss

    @State private var exporting = false
    @State private var pdfDocument: PDFReportDocument?

    private var check: CheckData? { model.checkData(forTransaction: txnID) }

    var body: some View {
        NavigationStack {
            Group {
                if let check {
                    ScrollView {
                        PrintableCheck(check: check)
                            .background(.white)
                            .overlay(Rectangle().strokeBorder(.quaternary))
                            .padding()
                    }
                } else {
                    ContentUnavailableView("Nothing to print",
                        systemImage: "checkmark.rectangle.stack",
                        description: Text("A check needs an amount paid out of a bank, cash or asset account."))
                }
            }
            .navigationTitle("Print Check")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save PDF…", systemImage: "square.and.arrow.down") { exportPDF() }
                        .disabled(check == nil)
                }
            }
            .fileExporter(isPresented: $exporting, document: pdfDocument,
                          contentType: .pdf,
                          defaultFilename: "Check \(check?.checkNumber ?? "")".trimmingCharacters(in: .whitespaces)) { _ in }
        }
        .frame(minWidth: 660, minHeight: 420)
    }

    private func exportPDF() {
        guard let check, let data = ReportExport.pdf(PrintableCheck(check: check)) else { return }
        pdfDocument = PDFReportDocument(data: data)
        exporting = true
    }
}

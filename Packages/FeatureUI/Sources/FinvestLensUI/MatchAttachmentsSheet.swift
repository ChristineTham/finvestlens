//
//  MatchAttachmentsSheet.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import UniformTypeIdentifiers
import FinvestLensEngine

/// Bulk attachment matching: pick a batch of receipts / invoices / dividend
/// statements (PDF or image); each is OCR'd, matched to its transaction by
/// amount and date — any account — and offered with the full attachment
/// categorisation (single category, invoice split, or franking split). Ticked
/// rows are applied together: the file is copied into the document folder and
/// linked, and the categorisation applied.
struct MatchAttachmentsSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDateFormat) private var dateFormat

    @State private var importerShown = false
    @State private var processing = false
    @State private var processTask: Task<Void, Never>?
    @State private var progress: (done: Int, total: Int)?
    @State private var matches: [AppModel.AttachmentMatch] = []
    @State private var accepted: Set<UUID> = []
    @State private var appliedSummary: String?
    /// The unmatched receipt being recorded as a fresh cash purchase.
    @State private var recordTarget: AppModel.AttachmentMatch?

    private var applyCount: Int {
        matches.filter { accepted.contains($0.id) && $0.transactionID != nil }.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if processing {
                    VStack(spacing: 12) {
                        ProgressView(value: progress.map { Double($0.done) } ?? 0,
                                     total: progress.map { Double($0.total) } ?? 1)
                            .frame(maxWidth: 320)
                        Text("Reading \( (progress?.done ?? 0) + 1 ) of \(progress?.total ?? 0)…")
                            .foregroundStyle(.secondary)
                        Button("Cancel", role: .cancel) { processTask?.cancel() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if matches.isEmpty {
                    ContentUnavailableView {
                        Label("Match Attachments", systemImage: "paperclip.badge.ellipsis")
                    } description: {
                        Text("Pick receipts, invoices or dividend statements (PDF or image). Each is matched to its transaction — in any account — then linked and categorised.")
                    } actions: {
                        Button("Choose Files…") { importerShown = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    // A ScrollView, not a List: List's row machinery swallows
                    // the drags text selection needs, and these rows' notes are
                    // exactly what one wants to copy out.
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if let appliedSummary {
                                Label(appliedSummary, systemImage: "checkmark.circle")
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 16).padding(.vertical, 8)
                                Divider()
                            }
                            Text("\(matches.count) file\(matches.count == 1 ? "" : "s")")
                                .scaledFont(.headline)
                                .padding(.horizontal, 16).padding(.vertical, 8)
                            ForEach(matches) { match in
                                row(match)
                                    .padding(.horizontal, 16).padding(.vertical, 6)
                                Divider()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .navigationTitle("Match Attachments")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem {
                    if !matches.isEmpty {
                        Button("Choose More…") { importerShown = true }
                            .disabled(processing)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Link & Categorise \(applyCount)") { apply() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(applyCount == 0 || processing)
                }
            }
            .sheet(item: $recordTarget) { match in
                RecordCashPurchaseSheet(model: model, match: match) { transactionID in
                    Task {
                        let url = match.url
                        let accessing = url.startAccessingSecurityScopedResource()
                        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                        let data = try? await Task.detached { try Data(contentsOf: url) }.value
                        if let data {
                            _ = try? model.attachDocument(named: match.fileName, data: data,
                                                          to: transactionID)
                        }
                        matches.removeAll { $0.id == match.id }
                        appliedSummary = "Recorded \(match.fileName) as a cash purchase and attached it."
                    }
                }
            }
            .fileImporter(isPresented: $importerShown,
                          allowedContentTypes: [.pdf, .image],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { process(urls) }
            }
        }
        .frame(minWidth: 680, minHeight: 460)
    }

    @ViewBuilder
    private func row(_ match: AppModel.AttachmentMatch) -> some View {
        let matched = match.transactionID != nil
        // The info stack sits BESIDE the checkbox, not inside its label —
        // text inside a control label can't be selected/copied, and the notes
        // are exactly what one wants to copy when a file doesn't match.
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { accepted.contains(match.id) },
                set: { isOn in
                    if isOn { accepted.insert(match.id) } else { accepted.remove(match.id) }
                }))
                .labelsHidden()
                .checkboxToggleStyle()
                .disabled(!matched)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: matched ? "doc.badge.plus" : "questionmark.circle")
                        .foregroundStyle(matched ? Color.accentColor : .secondary)
                    Text(match.fileName).fontWeight(.medium)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                    Button {
                        GeneralPasteboard.copy(details(of: match))
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .controlSize(.small)
                    .help("Copy this row’s details")
                    if !matched, !match.candidateAmounts.isEmpty {
                        Button("Record as Cash…", systemImage: "banknote") {
                            recordTarget = match
                        }
                        .controlSize(.small)
                        .help("The receipt matches no card/bank transaction — record it as a fresh cash purchase and attach the file")
                    }
                }
                if matched {
                    Text(match.transactionSummary)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let suggestion = match.suggestion {
                        if let friendly = suggestion.friendlyDescription {
                            Text("Rename to “\(friendly)” — bank text kept in the memo")
                                .scaledFont(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        if let lines = suggestion.lines {
                            ForEach(lines) { line in
                                HStack {
                                    Text("→ \(line.accountName)")
                                        .scaledFont(.caption)
                                        .lineLimit(1).truncationMode(.middle)
                                        .help(line.memo)
                                    Spacer()
                                    Text(AmountFormat.string(line.value, code: suggestion.currencyCode))
                                        .scaledFont(.caption).monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            Text("→ \(suggestion.accountName)")
                                .scaledFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Attach only — no categorisation suggested.")
                            .scaledFont(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text(match.note ?? "No match.")
                        .scaledFont(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy Details") { GeneralPasteboard.copy(details(of: match)) }
        }
    }

    /// Everything the row says, as plain text — for pasting into a report.
    private func details(of match: AppModel.AttachmentMatch) -> String {
        var lines = [match.fileName]
        if match.transactionID != nil { lines.append(match.transactionSummary) }
        if let note = match.note { lines.append(note) }
        if let suggestion = match.suggestion {
            if let friendly = suggestion.friendlyDescription {
                lines.append("Rename to “\(friendly)”")
            }
            if let split = suggestion.lines {
                for line in split {
                    lines.append("→ \(line.accountName)  \(AmountFormat.string(line.value, code: suggestion.currencyCode))")
                }
            } else {
                lines.append("→ \(suggestion.accountName)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func process(_ urls: [URL]) {
        processing = true
        appliedSummary = nil
        processTask = Task {
            defer { processing = false; progress = nil }
            // Security-scoped access for files picked via fileImporter.
            let scoped = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
            defer { for (url, accessing) in scoped where accessing { url.stopAccessingSecurityScopedResource() } }
            let results = await model.matchAttachments(urls: urls) { done, total in
                progress = (done, total)
            }
            matches.append(contentsOf: results)
            accepted.formUnion(results.filter { $0.transactionID != nil }.map(\.id))
        }
    }

    private func apply() {
        processing = true
        Task {
            defer { processing = false }
            var linked = 0
            var categorised = 0
            for match in matches where accepted.contains(match.id) {
                guard let transactionID = match.transactionID else { continue }
                let accessing = match.url.startAccessingSecurityScopedResource()
                defer { if accessing { match.url.stopAccessingSecurityScopedResource() } }
                // Read off the main actor: a cloud-backed file materialises on
                // read, which can take a while.
                let url = match.url
                let data = try? await Task.detached { try Data(contentsOf: url) }.value
                if let data,
                   (try? model.attachDocument(named: match.fileName, data: data,
                                              to: transactionID)) != nil {
                    linked += 1
                }
                if let suggestion = match.suggestion,
                   model.applyAttachmentSuggestion(suggestion, to: transactionID) {
                    categorised += 1
                }
            }
            appliedSummary = "Linked \(linked) attachment\(linked == 1 ? "" : "s"), categorised \(categorised)."
            matches.removeAll { accepted.contains($0.id) && $0.transactionID != nil }
            accepted.removeAll()
        }
    }
}


/// Records an unmatched receipt as a fresh two-leg purchase — cash accounts
/// don't appear on statements, so a cash receipt never has a transaction to
/// match. Prefilled from the document (vendor, date, amounts read); the file
/// is attached to the new transaction on save.
struct RecordCashPurchaseSheet: View {
    @Bindable var model: AppModel
    let match: AppModel.AttachmentMatch
    let onRecorded: (GncGUID) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var descriptionText = ""
    @State private var date = Date()
    @State private var amountText = ""
    @State private var payFromID: GncGUID?
    @State private var categoryID: GncGUID?

    private var cashAccounts: [AccountNode] {
        let cash = model.postableAccounts.filter { $0.typeName == "Cash" }
        return cash.isEmpty ? model.postableAccounts.filter { $0.typeName == "Bank" } : cash
    }

    private var amount: Decimal? { EditableSplit.strictDecimal(
        amountText.trimmingCharacters(in: .whitespaces)) }

    private var canRecord: Bool {
        payFromID != nil && categoryID != nil && (amount ?? 0) > 0
            && !descriptionText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Description", text: $descriptionText)
                DatePicker("Date", selection: $date, displayedComponents: .date)
                HStack {
                    TextField("Amount", text: $amountText)
                        .multilineTextAlignment(.trailing)
                    if match.candidateAmounts.count > 1 {
                        Menu {
                            ForEach(match.candidateAmounts, id: \.self) { candidate in
                                Button("\(candidate)") { amountText = "\(candidate)" }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                        }
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Amounts read from the receipt")
                    }
                }
                Picker("Pay from", selection: $payFromID) {
                    Text("Choose…").tag(GncGUID?.none)
                    ForEach(cashAccounts) { node in
                        Text(node.fullName).tag(GncGUID?.some(node.id))
                    }
                }
                Picker("Category", selection: $categoryID) {
                    Text("Choose…").tag(GncGUID?.none)
                    ForEach(model.postableAccounts) { node in
                        Text(node.fullName).tag(GncGUID?.some(node.id))
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Record Cash Purchase")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Record & Attach") {
                        guard let payFromID, let categoryID, let amount else { return }
                        if let id = model.quickEnter(
                            into: payFromID, transferFrom: categoryID,
                            amount: -amount, date: date,
                            description: descriptionText.trimmingCharacters(in: .whitespaces)) {
                            onRecorded(id)
                        }
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRecord)
                }
            }
            .onAppear {
                descriptionText = match.vendor?.trimmingCharacters(in: .whitespaces)
                    ?? Self.cleanName(match.fileName)
                date = match.documentDate ?? Date()
                if let first = match.candidateAmounts.first { amountText = "\(first)" }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
    }

    /// "2026-03-06 Spago.png" → "Spago".
    private static func cleanName(_ fileName: String) -> String {
        var name = (fileName as NSString).deletingPathExtension
        if let range = name.range(of: #"^\d{4}-\d{2}-\d{2}\s*"#, options: .regularExpression) {
            name.removeSubrange(range)
        }
        return name.trimmingCharacters(in: .whitespaces)
    }
}

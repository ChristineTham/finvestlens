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
    @State private var applying = false
    @State private var processTask: Task<Void, Never>?
    @State private var progress: (done: Int, total: Int)?
    @State private var matches: [AppModel.AttachmentMatch] = []
    @State private var accepted: Set<UUID> = []
    @State private var appliedSummary: String?
    /// The unmatched document opened in the manual transaction editor.
    @State private var editTarget: AppModel.AttachmentMatch?

    private var applyCount: Int {
        matches.filter { accepted.contains($0.id) && $0.transactionID != nil }.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if applying {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text("Linking and categorising…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if processing {
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
                            .disabled(processing || applying)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Link & Categorise \(applyCount)") { apply() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(applyCount == 0 || processing || applying)
                }
            }
            .sheet(item: $editTarget) { match in
                TransactionEditorSheet(
                    model: model,
                    documentPrefill: TransactionEditorSheet.DocumentPrefill(
                        url: match.url,
                        description: match.vendor,
                        date: match.documentDate,
                        amount: match.candidateAmounts.first,
                        currencyCode: match.currencyHint))
                    .onDisappear { matches.removeAll { $0.id == match.id } }
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
                    if !matched {
                        Button("Manually Edit…", systemImage: "square.and.pencil") {
                            editTarget = match
                        }
                        .controlSize(.small)
                        .help("Open the transaction editor with the document beside it — enter a new transaction, or link the document to an existing one")
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

    /// Copies the file into the document folder and links it to `transactionID`,
    /// off the main actor (cloud files materialise on read), then drops the row.
    private func attach(_ match: AppModel.AttachmentMatch, to transactionID: GncGUID,
                        summary: String) {
        Task {
            let url = match.url
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let data = try? await Task.detached { try Data(contentsOf: url) }.value
            if let data {
                model.attachDocumentReporting(named: match.fileName, data: data, to: transactionID)
            }
            matches.removeAll { $0.id == match.id }
            appliedSummary = summary
        }
    }

    private func apply() {
        applying = true
        Task {
            defer { applying = false }
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
                   model.attachDocumentReporting(named: match.fileName, data: data,
                                                 to: transactionID) {
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

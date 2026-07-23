//
//  AttachmentsPanel.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import QuickLook
import FinvestLensEngine
#if os(macOS)
import AppKit
import Quartz
import UniformTypeIdentifiers
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Puts a plain string on the system pasteboard.
enum GeneralPasteboard {
    static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = string
        #endif
    }
}

#if os(macOS)
/// Quick Look embedded in the sidebar (`QLPreviewView`) — the attachment shows
/// itself the moment its transaction is selected, no extra click.
private struct EmbeddedQuickLook: NSViewRepresentable {
    let url: URL

    final class Coordinator { var url: URL? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact) ?? QLPreviewView()
        view.shouldCloseWithWindow = false
        context.coordinator.url = url
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        view.previewItem = url as NSURL
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) {
        view.close()
    }
}
#endif

/// A trailing sidebar for the register showing the selected transaction's
/// document link (`assoc_uri`, FR-AI-08). The attachment previews inline the
/// moment its transaction is selected; the actions (open, reveal, replace,
/// remove, web link) sit at the bottom. Links are stored relative to the
/// document folder (Settings ▸ Documents) when the file lives inside it.
struct AttachmentsPanel: View {
    @Bindable var model: AppModel
    @State private var webLinkText = ""
    @State private var webFieldShown = false
    /// Full-window Quick Look (the expand button) — non-nil presents it.
    @State private var previewURL: URL?
    @State private var categorising = false
    @State private var categorySuggestion: AppModel.AttachmentCategorySuggestion?
    @State private var categoriseError: String?

    /// The single selected transaction, if the selection is exactly one.
    private var transactionID: GncGUID? {
        let ids = model.selectedTransactionIDs
        return ids.count == 1 ? ids.first : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Attachment", systemImage: "paperclip")
                .scaledFont(.headline)
            if let transactionID {
                if let link = model.documentLink(for: transactionID) {
                    linkContent(transactionID: transactionID, link: link)
                    categoriseControls(transactionID: transactionID, link: link)
                } else {
                    Text("No attachment on this transaction.")
                        .scaledFont(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Divider()
                addControls(transactionID: transactionID,
                            replacing: model.documentLink(for: transactionID) != nil)
            } else {
                Text(model.selectedTransactionIDs.isEmpty
                     ? "Select a transaction to see its attachment."
                     : "Select a single transaction.")
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(12)
        .frame(width: 290, alignment: .topLeading)
        .quickLookPreview($previewURL)
        .onChange(of: transactionID) {
            categorySuggestion = nil
            categoriseError = nil
            webFieldShown = false
            webLinkText = ""
        }
    }

    // MARK: Categorise from attachment (OCR + on-device model)

    @ViewBuilder
    private func categoriseControls(transactionID: GncGUID, link: String) -> some View {
        let isWeb = link.hasPrefix("http://") || link.hasPrefix("https://")
        let readable = !isWeb && (model.linkedDocumentURL(for: transactionID)
            .map { FileManager.default.fileExists(atPath: $0.path) } ?? false)

        VStack(alignment: .leading, spacing: 6) {
            Button {
                runCategorise(transactionID)
            } label: {
                if categorising {
                    HStack { ProgressView().controlSize(.small); Text("Reading…") }
                } else {
                    Label("Categorise from Attachment", systemImage: "sparkles")
                }
            }
            .disabled(!readable || categorising || !model.isIntelligenceAvailable)
            .help(model.intelligenceUnavailableReason
                  ?? "Read the attachment (OCR) and suggest a category for this transaction")
            if let suggestion = categorySuggestion {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Label(suggestion.accountName, systemImage: "arrow.right.circle")
                            .scaledFont(.callout)
                            .lineLimit(2)
                        Spacer()
                        Button("Apply") {
                            if model.applyAttachmentSuggestion(suggestion, to: transactionID) {
                                categorySuggestion = nil
                            } else {
                                categoriseError = "Couldn’t apply — edit the splits in the inspector (⌘E)."
                            }
                        }
                        .controlSize(.small)
                    }
                    if let friendly = suggestion.friendlyDescription {
                        Text("Rename to “\(friendly)” — bank text kept in the memo")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // A multi-item invoice: one leg per line item.
                    if let lines = suggestion.lines {
                        ForEach(lines) { line in
                            HStack(spacing: 4) {
                                Text("→ \(line.accountName)")
                                    .scaledFont(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(line.memo)
                                Spacer()
                                Text(AmountFormat.string(line.value, code: suggestion.currencyCode))
                                    .scaledFont(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if let categoriseError {
                Text(categoriseError)
                    .scaledFont(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func runCategorise(_ transactionID: GncGUID) {
        categorising = true
        categoriseError = nil
        categorySuggestion = nil
        Task {
            defer { categorising = false }
            do {
                if let result = try await model.suggestCategoryFromAttachment(for: transactionID) {
                    categorySuggestion = result
                } else {
                    categoriseError = "No confident suggestion from the attachment."
                }
            } catch {
                categoriseError = error.localizedDescription
            }
        }
    }

    // MARK: Link display

    @ViewBuilder
    private func linkContent(transactionID: GncGUID, link: String) -> some View {
        let isWeb = link.hasPrefix("http://") || link.hasPrefix("https://")
        let url = isWeb ? nil : model.linkedDocumentURL(for: transactionID)
        let exists = isWeb ? true
            : (url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)

        // The preview fills the panel; details and actions sit under it.
        if !isWeb, exists, let url {
            #if os(macOS)
            EmbeddedQuickLook(url: url)
                .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
            #else
            Button {
                previewURL = url
            } label: {
                Label("Preview", systemImage: "eye")
            }
            Spacer()
            #endif
        } else {
            Spacer()
        }

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: isWeb ? "link" : "doc")
                    .foregroundStyle(.secondary)
                Text(isWeb ? link : (url?.lastPathComponent ?? link))
                    .scaledFont(.callout)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .contextMenu {
                        Button("Copy Name") {
                            GeneralPasteboard.copy(isWeb ? link : (url?.lastPathComponent ?? link))
                        }
                        Button(isWeb ? "Copy Link" : "Copy Full Path") {
                            GeneralPasteboard.copy(isWeb ? link : (url?.path ?? link))
                        }
                        if !isWeb {
                            Button("Copy Stored Link") { GeneralPasteboard.copy(link) }
                        }
                    }
                Spacer()
                if !isWeb, exists, let url {
                    Button {
                        previewURL = url
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Open the full Quick Look window")
                }
            }
            // The raw stored link — the relative path is the durable fact.
            Text(link)
                .scaledFont(.caption)
                .monospaced()
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if !exists {
                Label("File not found under the document folder.",
                      systemImage: "exclamationmark.triangle")
                    .scaledFont(.caption)
                    .foregroundStyle(.orange)
            }
        }

        HStack {
            if isWeb {
                Button("Open") {
                    #if os(macOS)
                    if let webURL = URL(string: link) { NSWorkspace.shared.open(webURL) }
                    #endif
                }
            } else {
                Button {
                    model.openLinkedDocument(for: transactionID)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .disabled(!exists)
                .help("Open in its application")
                #if os(macOS)
                if let url {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .disabled(!exists)
                    .help("Reveal in Finder")
                }
                #endif
            }
            Spacer()
            Button("Remove", role: .destructive) {
                model.setDocumentLink(nil, for: transactionID)
            }
            .help("Removes the link only — the file stays where it is")
        }
        .controlSize(.small)
    }

    // MARK: Add / replace

    @ViewBuilder
    private func addControls(transactionID: GncGUID, replacing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            #if os(macOS)
            Button(replacing ? "Replace with File…" : "Link File…",
                   systemImage: "doc.badge.plus") {
                if let url = MacFilePanel.open(types: [.item],
                                               title: "Choose a file to link") {
                    model.linkDocument(at: url, to: transactionID)
                }
            }
            .help("Opens a file dialog — the chosen file is linked in place, stored relative to the document folder (Settings ▸ Documents) when inside it")
            #endif
            // The URL field only appears on demand: a permanently visible blank
            // field read like the replace control.
            if webFieldShown {
                HStack(spacing: 6) {
                    TextField("https://…", text: $webLinkText)
                        .textFieldStyle(.roundedBorder)
                        .scaledFont(.callout)
                        .onSubmit { setWebLink(transactionID: transactionID) }
                    Button("Set") { setWebLink(transactionID: transactionID) }
                        .disabled(!(webLinkText.hasPrefix("http://")
                                    || webLinkText.hasPrefix("https://")))
                    Button {
                        webFieldShown = false
                        webLinkText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .controlSize(.small)
            } else {
                Button(replacing ? "Replace with Web Link…" : "Add Web Link…",
                       systemImage: "link") {
                    webFieldShown = true
                }
            }
        }
    }

    private func setWebLink(transactionID: GncGUID) {
        let trimmed = webLinkText.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return }
        model.setDocumentLink(trimmed, for: transactionID)
        webLinkText = ""
        webFieldShown = false
    }
}

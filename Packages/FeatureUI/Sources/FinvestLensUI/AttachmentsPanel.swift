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
import UniformTypeIdentifiers
#endif

/// A trailing sidebar for the register showing the selected transaction's
/// document link (`assoc_uri`, FR-AI-08) — open, reveal, replace or remove it,
/// link an existing file in place, or add a web link. Links are stored relative
/// to the document folder (Settings ▸ Documents) when the file lives inside it.
struct AttachmentsPanel: View {
    @Bindable var model: AppModel
    @State private var webLinkText = ""
    /// The file being previewed — non-nil presents the Quick Look panel.
    @State private var previewURL: URL?

    /// The single selected transaction, if the selection is exactly one.
    private var transactionID: GncGUID? {
        let ids = model.selectedTransactionIDs
        return ids.count == 1 ? ids.first : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Attachment", systemImage: "paperclip")
                .scaledFont(.headline)
            if let transactionID {
                if let link = model.documentLink(for: transactionID) {
                    linkDetails(transactionID: transactionID, link: link)
                } else {
                    Text("No attachment on this transaction.")
                        .scaledFont(.callout)
                        .foregroundStyle(.secondary)
                }
                Divider()
                addControls(transactionID: transactionID,
                            replacing: model.documentLink(for: transactionID) != nil)
                Spacer()
                Text("File links are stored relative to the document folder (Settings ▸ Documents ⌘,) when the file lives inside it, so the book and its documents can move together.")
                    .scaledFont(.caption)
                    .foregroundStyle(.tertiary)
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
        .frame(width: 270, alignment: .topLeading)
        .quickLookPreview($previewURL)
    }

    @ViewBuilder
    private func linkDetails(transactionID: GncGUID, link: String) -> some View {
        let isWeb = link.hasPrefix("http://") || link.hasPrefix("https://")
        let url = isWeb ? nil : model.linkedDocumentURL(for: transactionID)
        let exists = isWeb ? true
            : (url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)

        VStack(alignment: .leading, spacing: 6) {
            // The name itself Quick Looks the file (web links open in the
            // browser) — the fastest "what is this?" gesture.
            Button {
                if isWeb {
                    #if os(macOS)
                    if let webURL = URL(string: link) { NSWorkspace.shared.open(webURL) }
                    #endif
                } else if exists {
                    previewURL = url
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isWeb ? "link" : "doc")
                        .foregroundStyle(.secondary)
                    Text(isWeb ? link : (url?.lastPathComponent ?? link))
                        .scaledFont(.body)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isWeb ? "Open in the browser" : "Quick Look")
            // The raw stored link — the relative path is the durable fact.
            Text(link)
                .scaledFont(.caption)
                .monospaced()
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if !exists {
                Label("File not found under the document folder.",
                      systemImage: "exclamationmark.triangle")
                    .scaledFont(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                if isWeb {
                    Button("Open") {
                        #if os(macOS)
                        if let webURL = URL(string: link) { NSWorkspace.shared.open(webURL) }
                        #endif
                    }
                } else {
                    Button("Quick Look", systemImage: "eye") { previewURL = url }
                        .disabled(!exists)
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
    }

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
            .help("Links the file in place — stored relative to the document folder when inside it")
            #endif
            HStack(spacing: 6) {
                TextField("https://…", text: $webLinkText)
                    .textFieldStyle(.roundedBorder)
                    .scaledFont(.callout)
                Button(replacing ? "Replace" : "Add") {
                    let trimmed = webLinkText.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return }
                    model.setDocumentLink(trimmed, for: transactionID)
                    webLinkText = ""
                }
                .disabled(!(webLinkText.hasPrefix("http://") || webLinkText.hasPrefix("https://")))
            }
            .controlSize(.small)
        }
    }
}

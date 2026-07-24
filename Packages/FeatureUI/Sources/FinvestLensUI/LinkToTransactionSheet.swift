//
//  LinkToTransactionSheet.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine

/// Manual link: pick the transaction an unmatched document belongs to (any
/// account, any date). The escape hatch for what auto-match can't reach —
/// foreign-currency invoices, deposits, and future-dated charges — where the
/// document's amount or date deliberately won't equal the transaction's.
struct LinkToTransactionSheet: View {
    @Bindable var model: AppModel
    let match: AppModel.AttachmentMatch
    let onLinked: (GncGUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDateFormat) private var dateFormat
    @State private var query = ""

    var body: some View {
        NavigationStack {
            let picks = model.transactionsForLinking(query: query)
            List(picks) { pick in
                Button {
                    onLinked(pick.id)
                    dismiss()
                } label: {
                    HStack(spacing: 6) {
                        if pick.hasDocument {
                            Image(systemName: "paperclip").foregroundStyle(.secondary)
                                .help("Already has an attachment")
                        }
                        Text(pick.summary).scaledFont(.callout)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $query, prompt: "Search description, amount, or date (13/3)")
            .safeAreaInset(edge: .bottom) {
                if picks.count >= 400 {
                    Text("Showing the latest 400 — search to narrow further.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
            }
            .navigationTitle("Link “\(match.fileName)”")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}

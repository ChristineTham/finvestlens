//
//  AccountMatchPicker.swift
//  FinvestLens — FeatureUI
//
//  Choosing accounts for Find's Account criterion — GnuCash's "Select Accounts
//  to Match".
//
//  GnuCash shows a collapsed tree, and on a book with 559 accounts that is the
//  right call: nine top-level rows you can navigate beat one list you cannot.
//  It has no filter, though, so reaching Assets:Joint:CDIA still means opening
//  three disclosure triangles. This keeps the tree and adds the filter — with
//  no filter text you get GnuCash's shape, and typing flattens to matches.
//
//  Only postable accounts carry a checkbox. Placeholders hold no splits, so
//  selecting one would match nothing; they are shown, because they are how you
//  navigate to the accounts underneath, but they are structure, not choices.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine

struct AccountMatchPicker: View {
    let tree: [AccountNode]
    @Binding var selection: Set<GncGUID>
    @Environment(\.dismiss) private var dismiss

    @State private var filter = ""

    private var trimmedFilter: String {
        filter.trimmingCharacters(in: .whitespaces)
    }

    private var matches: [AccountNode] {
        Self.matching(tree, filter: trimmedFilter)
    }

    /// Filtering flattens: when you have typed "cdia" you want the account, not
    /// its ancestry. Matching on the **full** name is what makes "joint:cdia"
    /// narrow further, and what lets a parent's name find its children.
    /// Placeholders never match — they cannot be chosen, so offering them as
    /// search results would be offering nothing.
    static func matching(_ tree: [AccountNode], filter: String) -> [AccountNode] {
        func flatten(_ nodes: [AccountNode]) -> [AccountNode] {
            nodes.flatMap { [$0] + flatten($0.children ?? []) }
        }
        let needle = filter.lowercased()
        return flatten(tree).filter { node in
            guard !node.isPlaceholder else { return false }
            // `"abc".contains("")` is false in Swift, so an empty needle has to
            // be handled rather than left to fall through as "matches nothing".
            return needle.isEmpty || node.fullName.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter accounts", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(8)

            Divider()

            List {
                if trimmedFilter.isEmpty {
                    OutlineGroup(tree, children: \.children) { node in
                        row(node, label: node.name)
                    }
                } else if matches.isEmpty {
                    Text("No accounts match “\(trimmedFilter)”.")
                        .foregroundStyle(.secondary)
                        .scaledFont(.callout)
                } else {
                    ForEach(matches) { node in
                        row(node, label: node.fullName)
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Text(summary).scaledFont(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { selection.removeAll() }
                    .disabled(selection.isEmpty)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(8)
        }
        .frame(width: 420, height: 420)
    }

    private var summary: String {
        switch selection.count {
        case 0: "No accounts selected"
        case 1: "1 account selected"
        default: "\(selection.count) accounts selected"
        }
    }

    @ViewBuilder
    private func row(_ node: AccountNode, label: String) -> some View {
        if node.isPlaceholder {
            // Navigable, not selectable.
            Text(node.name)
                .scaledFont(.body)
                .foregroundStyle(.secondary)
        } else {
            Button {
                if selection.contains(node.id) {
                    selection.remove(node.id)
                } else {
                    selection.insert(node.id)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: selection.contains(node.id)
                          ? "checkmark.square.fill" : "square")
                        .foregroundStyle(selection.contains(node.id) ? Color.accentColor : .secondary)
                    Text(label).scaledFont(.body)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }
}

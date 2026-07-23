//
//  AccountField.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  A searchable account chooser (GnuCash's register autocomplete): type a few
//  characters and a filtered list drops down; pick one, or press Return to
//  take the best match. Replaces long scrolling `Picker`s of 500+ accounts.
//

import SwiftUI
import FinvestLensEngine

enum AccountSearch {
    /// Accounts whose full name contains every whitespace-separated term of
    /// `query` (so "joint cdia" narrows the same way GnuCash's does). An empty
    /// query returns everything, in the given order.
    static func matches(_ query: String, in nodes: [AccountNode]) -> [AccountNode] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return nodes }
        return nodes.filter { node in
            let name = node.fullName.lowercased()
            return terms.allSatisfy { name.contains($0) }
        }
    }

    static func name(of id: GncGUID?, in nodes: [AccountNode]) -> String {
        id.flatMap { target in nodes.first { $0.id == target }?.fullName } ?? ""
    }
}

/// An inline searchable account field for use inside a `Form`. Shows the chosen
/// account's full name; focusing turns it into a search box with a dropdown of
/// matches beneath.
struct AccountField: View {
    var prompt: String = "Search account…"
    let nodes: [AccountNode]
    @Binding var selection: GncGUID?
    /// Rows shown in the dropdown at once.
    var limit: Int = 8

    @State private var query = ""
    @State private var showList = false
    @FocusState private var focused: Bool

    private var selectedName: String { AccountSearch.name(of: selection, in: nodes) }
    private var matches: [AccountNode] { AccountSearch.matches(query, in: nodes) }
    /// The field's text already names the selection exactly — nothing to offer.
    private var settled: Bool { query == selectedName }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                TextField(prompt, text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { takeBestMatch() }
                if selection != nil, !focused {
                    Button {
                        selection = nil
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Clear")
                } else {
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            // The border is what tells the eye "this is a field you can type
            // into" — borderless, the picker was invisible until clicked.
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(focused ? Color.accentColor : Color.secondary.opacity(0.35),
                                  lineWidth: focused ? 1.5 : 1)
            )
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            if showList, !settled {
                VStack(alignment: .leading, spacing: 0) {
                    if matches.isEmpty {
                        Text("No accounts match “\(query)”.")
                            .scaledFont(.caption).foregroundStyle(.secondary)
                            .padding(.vertical, 3)
                    } else {
                        ForEach(matches.prefix(limit)) { node in
                            Button { pick(node) } label: {
                                Text(node.fullName)
                                    .scaledFont(.callout)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding(6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .onAppear { query = selectedName }
        .onChange(of: selection) { query = selectedName }
        .onChange(of: focused) { _, isFocused in
            if isFocused {
                showList = true
            } else {
                // A blur races the tap that picks a row: hold the list briefly
                // so the pick lands, then revert unfinished typing.
                Task {
                    try? await Task.sleep(for: .milliseconds(180))
                    if !focused {
                        showList = false
                        if !settled { query = selectedName }
                    }
                }
            }
        }
        .onChange(of: query) { if focused { showList = true } }
    }

    private func pick(_ node: AccountNode) {
        selection = node.id
        query = node.fullName
        showList = false
        focused = false
    }

    /// Return commits the single best match: an exact full-name hit, else the
    /// first of the current filter.
    private func takeBestMatch() {
        if let exact = matches.first(where: { $0.fullName.caseInsensitiveCompare(query) == .orderedSame }) {
            pick(exact)
        } else if let first = matches.first {
            pick(first)
        }
    }
}

/// A compact searchable account chooser for dense contexts (register table
/// cells): reads as plain text, opens a search-and-pick popover on click. The
/// popover owns keyboard focus, so there is no field-blur race.
struct AccountPickerButton: View {
    var label: String
    let nodes: [AccountNode]
    let onPick: (GncGUID) -> Void

    @State private var open = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var matches: [AccountNode] { AccountSearch.matches(query, in: nodes) }

    var body: some View {
        Button { open = true } label: {
            Text(label.isEmpty ? "—" : label)
                .scaledFont(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                TextField("Search accounts", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onSubmit { if let first = matches.first { choose(first) } }
                    .padding(8)
                Divider()
                List(matches.prefix(60).map { $0 }) { node in
                    Button { choose(node) } label: {
                        Text(node.fullName).frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: 360, height: 300)
            }
            .onAppear { query = ""; searchFocused = true }
        }
    }

    private func choose(_ node: AccountNode) {
        onPick(node.id)
        open = false
    }
}

//
//  AccountField.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  A searchable account chooser (GnuCash's register autocomplete) in two
//  strict modes. **Display**: the chosen account's full name, rendered
//  directly from the binding on every pass — there is no cached text to go
//  stale, so a selected account can never show a placeholder. **Search**:
//  entered by clicking, starts empty, filters as you type; pick a row or
//  press Return for the best match; clicking away cancels back to display.
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

struct AccountField: View {
    var prompt: String = "Account"
    let nodes: [AccountNode]
    @Binding var selection: GncGUID?
    /// Rows shown in the dropdown at once.
    var limit: Int = 8

    @State private var searching = false
    @State private var query = ""
    @FocusState private var focused: Bool

    private var selectedName: String { AccountSearch.name(of: selection, in: nodes) }
    private var matches: [AccountNode] { AccountSearch.matches(query, in: nodes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if searching {
                searchField
                dropdown
            } else {
                displayButton
            }
        }
    }

    // MARK: Display mode — a pure function of the selection

    private var displayButton: some View {
        Button {
            beginSearch()
        } label: {
            HStack(spacing: 4) {
                Text(selectedName.isEmpty ? prompt : selectedName)
                    .foregroundStyle(selectedName.isEmpty ? .tertiary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(selectedName.isEmpty ? "Choose an account" : selectedName)
    }

    // MARK: Search mode

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .imageScale(.small)
                .foregroundStyle(.tertiary)
            TextField("Type to search", text: $query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { takeBestMatch() }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
        )
        .onChange(of: focused) { _, isFocused in
            guard !isFocused else { return }
            // A blur races the tap that picks a row: give the pick a moment to
            // land, then cancel back to display mode (selection untouched).
            Task {
                try? await Task.sleep(for: .milliseconds(180))
                if !focused { searching = false }
            }
        }
    }

    @ViewBuilder
    private var dropdown: some View {
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
                            .lineLimit(1)
                            .truncationMode(.middle)
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

    private func beginSearch() {
        query = ""
        searching = true
        // The field has to exist before it can take focus.
        Task { focused = true }
    }

    private func pick(_ node: AccountNode) {
        selection = node.id
        searching = false
        focused = false
    }

    /// Return commits the single best match of the current filter.
    private func takeBestMatch() {
        if let exact = matches.first(where: { $0.fullName.caseInsensitiveCompare(query) == .orderedSame }) {
            pick(exact)
        } else if let first = matches.first {
            pick(first)
        } else {
            searching = false
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

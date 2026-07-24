//
//  HelpView.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// A lightweight in-app help / keyboard-shortcut reference reached from the Help
/// menu — FinvestLens has no bundled help book yet, so this is the "Help book /
/// anchors" surface.
public struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    public init() {}

    private struct Shortcut: Identifiable {
        let id = UUID()
        let keys: String
        let action: String
    }

    private let shortcuts: [Shortcut] = [
        .init(keys: "⌘N", action: "New book"),
        .init(keys: "⌘O", action: "Open book"),
        .init(keys: "⌘S", action: "Save"),
        .init(keys: "⌘T", action: "New transaction"),
        .init(keys: "⇧⌘N", action: "New account"),
        .init(keys: "⌘E", action: "Edit selected transaction"),
        .init(keys: "⌘J", action: "Jump to the other account"),
        .init(keys: "⌘F", action: "Find transactions"),
        .init(keys: "⌘I", action: "Find account"),
        .init(keys: "⌥⌘I", action: "Import a bank file"),
        .init(keys: "⇧⌘R", action: "Reconcile account"),
        .init(keys: "⌘R", action: "Reports"),
        .init(keys: "⌘B", action: "Budget"),
        .init(keys: "⌘D", action: "Dashboard"),
        .init(keys: "⇧⌘L", action: "Lock the book now"),
    ]

    public var body: some View {
        NavigationStack {
            List {
                Section("Getting started") {
                    Text("Open a GnuCash file with File ▸ Import GnuCash…, or create a new book with ⌘N. Everything you do is undoable, and the book saves back to its file on ⌘S, autosave (Settings ▸ General), or when you close it.")
                        .scaledFont(.callout)
                }
                Section("Search operators") {
                    Text("The search box understands `tag:`, `account:`/`category:`, `memo:`, `desc:`, `amount:>N`/`<N`, `from:`/`to:` (a date, `today`, or `-7d`/`-2w`/`-3m`/`-1y`), `type:`, and `has:attachment`. Prefix any token with `-` to negate it.")
                        .scaledFont(.callout)
                }
                Section("Keyboard shortcuts") {
                    ForEach(shortcuts) { shortcut in
                        LabeledContent(shortcut.action) {
                            Text(shortcut.keys).monospaced().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("FinvestLens Help")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
    }
}

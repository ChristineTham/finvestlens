//
//  DocumentSettingsView.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// The Documents preferences: where linked documents (invoices, dividend
/// statements) are stored and how relative links resolve — GnuCash calls
/// this the association "path head" (`FR-AI-08`).
public struct DocumentSettingsView: View {
    @AppStorage(AppModel.documentFolderDefaultsKey) private var folderPath = ""

    public init() {}

    public var body: some View {
        Form {
            Section("Document folder") {
                LabeledContent("Folder") {
                    Text(folderPath.isEmpty ? "Same folder as the book" : folderPath)
                        .foregroundStyle(folderPath.isEmpty ? .secondary : .primary)
                        .truncationMode(.middle)
                        .lineLimit(1)
                }
                HStack {
                    Button("Choose…") {
                        #if os(macOS)
                        if let url = MacFilePanel.chooseDirectory(
                            title: "Choose the folder for linked documents") {
                            folderPath = url.path
                        }
                        #endif
                    }
                    Button("Use Book Folder") { folderPath = "" }
                        .disabled(folderPath.isEmpty)
                }
                Text("PDFs imported by Smart Import are copied here and linked to their transaction as a relative path — the same scheme as GnuCash document links, so links survive export. Keeping documents next to the book means both move together (e.g. on a NAS).")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 220)
        .navigationTitle("Documents")
    }
}

/// General preferences: autosave (`FR-DAT-10`).
public struct GeneralSettingsView: View {
    @AppStorage("finvestlens.autosaveIntervalSeconds") private var autosaveSeconds = 300
    @AppStorage(AppModel.reopenLastBookDefaultsKey) private var reopenLastBook = true

    public init() {}

    public var body: some View {
        Form {
            Section("On launch") {
                Toggle("Reopen the last book", isOn: $reopenLastBook)
                Text("When on, FinvestLens reopens the book you had open when you last quit.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Autosave") {
                Picker("Save automatically", selection: $autosaveSeconds) {
                    Text("Off").tag(0)
                    Text("Every minute").tag(60)
                    Text("Every 5 minutes").tag(300)
                    Text("Every 10 minutes").tag(600)
                    Text("Every 15 minutes").tag(900)
                }
                Text(autosaveSeconds == 0
                     ? "Autosave is off — changes are written only on Save (⌘S) or when closing the book."
                     : "The working copy is written back to the document on this interval while there are unsaved changes. Save (⌘S) and save-on-close still apply.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 220)
        .navigationTitle("General")
    }
}

/// Tabbed Settings window: General + Appearance + Documents.
public struct FinvestLensSettingsView: View {
    public init() {}

    public var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            DocumentSettingsView()
                .tabItem { Label("Documents", systemImage: "paperclip") }
        }
    }
}

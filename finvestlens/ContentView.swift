//
//  ContentView.swift
//  finvestlens
//
//  Created by Chris Tham on 12/7/2026.
//
//  This file is part of FinvestLens.
//
//  Copyright (C) 2026 Christine Tham
//
//  FinvestLens is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  FinvestLens is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with FinvestLens.  If not, see <https://www.gnu.org/licenses/>.
//

import SwiftUI
import UniformTypeIdentifiers
import FinvestLensUI

/// Hosts either the welcome screen or an open document, and surfaces
/// document-operation errors (with stale-lock recovery) and confirmations.
struct RootHost: View {
    @Bindable var model: AppModel
    @Environment(\.undoManager) private var undoManager
    @State private var importing = false

    static var documentType: UTType {
        UTType(exportedAs: "com.hellotham.finvestlens.document", conformingTo: .database)
    }

    var body: some View {
        Group {
            if model.isOpen && model.isLocked {
                LockView(model: model)
            } else if model.isOpen, let url = model.documentURL {
                FinvestLensRootView(model: model)
                    // HIG: name the window after the open document, with a
                    // titlebar proxy icon (drag / reveal-in-Finder).
                    .navigationDocument(url)
            } else {
                WelcomeView(model: model, onNew: newBook, onOpen: openBook)
            }
        }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager == nil) { model.undoManager = undoManager }
        .fileImporter(isPresented: $importing, allowedContentTypes: [Self.documentType, .data]) { result in
            if case .success(let url) = result { model.openBook(at: url) }
        }
        .alert("Couldn’t open book",
               isPresented: Binding(get: { model.documentError != nil },
                                    set: { if !$0 { model.documentError = nil } }),
               presenting: model.documentError) { error in
            if let lockedURL = error.lockedURL {
                Button("Break Lock and Open") {
                    model.openBook(at: lockedURL, breakStaleLock: true)
                }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { error in
            Text(error.message)
        }
        .alert("Import Complete",
               isPresented: Binding(get: { model.infoMessage != nil },
                                    set: { if !$0 { model.infoMessage = nil } })) {
            Button("OK", role: .cancel) { model.infoMessage = nil }
        } message: {
            Text(model.infoMessage ?? "")
        }
    }

    private func newBook() {
        #if os(macOS)
        DocumentDialogs.newBook(model)
        #else
        let name = "Untitled-\(UUID().uuidString.prefix(6)).finvestlens"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        model.newBook(at: url)
        #endif
    }

    private func openBook() {
        #if os(macOS)
        DocumentDialogs.openBook(model)
        #else
        importing = true
        #endif
    }
}

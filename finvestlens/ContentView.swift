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

/// Hosts either the welcome screen or an open document.
struct RootHost: View {
    @Bindable var model: AppModel
    @State private var importing = false
    @State private var errorMessage: String?

    static var documentType: UTType {
        UTType(exportedAs: "com.hellotham.finvestlens.document", conformingTo: .database)
    }

    var body: some View {
        Group {
            if model.isOpen && model.isLocked {
                LockView(model: model)
            } else if model.isOpen {
                FinvestLensRootView(model: model)
            } else {
                WelcomeView(onNew: newTemporary) { importing = true }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [Self.documentType, .data]) { result in
            if case .success(let url) = result {
                do { try model.open(at: url) }
                catch { errorMessage = error.localizedDescription }
            }
        }
        .alert("Couldn’t open document",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func newTemporary() {
        let name = "Untitled-\(UUID().uuidString.prefix(6)).finvestlens"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? model.newDocument(at: url)
    }
}

//
//  DocumentDialogs.swift
//  finvestlens
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensUI

#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// AppKit open/save dialogs backing the File menu and welcome screen (macOS).
@MainActor
enum DocumentDialogs {

    static var documentType: UTType {
        UTType(exportedAs: "com.hellotham.finvestlens.document", conformingTo: .database)
    }

    /// File ▸ New Book…: choose where the new book lives, then create it.
    static func newBook(_ model: AppModel) {
        let panel = NSSavePanel()
        panel.title = "New Book"
        panel.nameFieldStringValue = "My Book"   // panel appends .finvestlens
        panel.allowedContentTypes = [documentType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.newBook(at: url)
    }

    /// File ▸ Open…: pick an existing .finvestlens book.
    static func openBook(_ model: AppModel) async {
        let panel = NSOpenPanel()
        panel.title = "Open Book"
        panel.allowedContentTypes = [documentType, .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await model.openBook(at: url)
    }

    /// File ▸ Import GnuCash…: pick the GnuCash XML, then where to save the
    /// converted native book.
    static func importGnuCash(_ model: AppModel) {
        let open = NSOpenPanel()
        open.title = "Import GnuCash File"
        open.message = "Choose a GnuCash file (XML, optionally gzip-compressed)."
        open.allowedContentTypes = [.xml, .data]
        open.allowsOtherFileTypes = true
        open.allowsMultipleSelection = false
        guard open.runModal() == .OK, let source = open.url else { return }

        let save = NSSavePanel()
        save.title = "Save Imported Book"
        save.message = "Choose where to save the converted FinvestLens book."
        save.nameFieldStringValue = source.deletingPathExtension()
            .lastPathComponent + ".finvestlens"
        save.allowedContentTypes = [documentType]
        save.canCreateDirectories = true
        guard save.runModal() == .OK, let destination = save.url else { return }

        model.importGnuCashBook(from: source, saveAs: destination)
    }
}
#endif

//
//  PreviewProvider.swift
//  FinvestLens — Quick Look preview extension
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Quick Look preview for a `.finvestlens` book (FR-PLT-03). Unlike the widget,
//  this previews an arbitrary file the user selected in Finder — not the
//  last-opened book — so it reads that file directly. It uses the system
//  SQLite3 (read-only, no GRDB / Engine) to pull a few headline counts, keeping
//  the extension light and free of the app's dependency graph.
//

import Foundation
import QuickLook
#if canImport(QuickLookUI)
import QuickLookUI   // QLPreviewingController lives here on macOS
#endif
import SwiftUI
import SQLite3

#if os(macOS)
import AppKit
typealias PlatformViewController = NSViewController
typealias PlatformHostingController = NSHostingController
#else
import UIKit
typealias PlatformViewController = UIViewController
typealias PlatformHostingController = UIHostingController
#endif

/// A few cheap headline figures read straight from the book's SQLite tables.
struct BookSummary {
    var accounts = 0
    var transactions = 0
    var prices = 0
    var commodities = 0
    var readable = false

    static func read(from url: URL) -> BookSummary {
        var summary = BookSummary()
        var db: OpaquePointer?
        // SQLITE_OPEN_READONLY — never modify the previewed file.
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return summary
        }
        defer { sqlite3_close(db) }

        func count(_ table: String) -> Int {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT count(*) FROM \"\(table)\"", -1, &stmt, nil) == SQLITE_OK else {
                return 0
            }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }

        summary.accounts = count("account")
        summary.transactions = count("txn")
        summary.prices = count("price")
        summary.commodities = count("commodity")
        summary.readable = true
        return summary
    }
}

struct BookPreview: View {
    let name: String
    let summary: BookSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "building.columns")
                    .font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.title2).fontWeight(.semibold).lineLimit(1)
                    Text("FinvestLens Book").font(.callout).foregroundStyle(.secondary)
                }
            }

            if summary.readable {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                    row("Accounts", summary.accounts)
                    row("Transactions", summary.transactions)
                    row("Commodities", summary.commodities)
                    row("Prices", summary.prices)
                }
                .font(.body.monospacedDigit())
            } else {
                Text("Preview unavailable")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ label: String, _ value: Int) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value.formatted(.number)).gridColumnAlignment(.trailing)
        }
    }
}

/// The Quick Look preview controller. `QLSupportedContentTypes` in Info.plist
/// scopes it to the `.finvestlens` UTI.
class PreviewViewController: PlatformViewController, QLPreviewingController {

    func preparePreviewOfFile(at url: URL) async throws {
        let summary = BookSummary.read(from: url)
        let name = url.deletingPathExtension().lastPathComponent
        let host = PlatformHostingController(rootView: BookPreview(name: name, summary: summary))

        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        #if !os(macOS)
        host.didMove(toParent: self)
        #endif
    }
}

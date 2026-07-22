//
//  TransactionClipboard.swift
//  FinvestLens — FeatureUI
//
//  GnuCash's Cut / Copy / Paste Transaction (`FR-REG-09`).
//
//  `duplicateTransaction` already covers copying a transaction where it stands.
//  What the clipboard adds is the other register — and the other *book*: copy a
//  transaction here, paste it there. So this goes through the system pasteboard
//  rather than a variable on the model, which would only ever reach as far as
//  the window it was set in.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
#if os(macOS)
import AppKit
#endif

/// A transaction on the clipboard.
///
/// Carries what a transaction *is*, and deliberately not what has happened to
/// it: no reconcile state, no reconcile date, no identity. A pasted transaction
/// is a new one that nobody has agreed to yet, the same reasoning that makes
/// Duplicate leave those behind.
public struct TransactionClipboard: Codable, Sendable, Equatable {

    /// One leg, named twice.
    ///
    /// By GUID, which is the answer within a book, and by full name, which is
    /// the only thing that means anything in another one. Pasting across books
    /// is the case the pasteboard exists for, and a GUID from someone else's
    /// file resolves to nothing.
    public struct Leg: Codable, Sendable, Equatable {
        public var accountGUID: GncGUID
        public var accountFullName: String
        public var value: Decimal
        public var quantity: Decimal
        public var memo: String
        public var action: String
    }

    public var datePosted: Date
    public var number: String
    public var transactionDescription: String
    public var notes: String
    public var currency: Commodity
    public var legs: [Leg]

    /// The pasteboard type. Private to the app: this is JSON of an internal
    /// shape, and nothing else should be reading it.
    public static let pasteboardType = "com.hellotham.finvestlens.transaction"
}

/// Reads and writes ``TransactionClipboard`` on the system pasteboard.
public enum TransactionPasteboard {

    /// Puts a transaction on the pasteboard, replacing what was there.
    public static func write(_ clipboard: TransactionClipboard) {
        guard let data = try? JSONEncoder().encode(clipboard) else { return }
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .init(TransactionClipboard.pasteboardType))
        // A plain-text copy alongside it, so pasting into a mail or a note gives
        // something to read rather than nothing.
        pasteboard.setString(describe(clipboard), forType: .string)
        #else
        stored = data
        #endif
    }

    /// The transaction on the pasteboard, if there is one.
    public static func read() -> TransactionClipboard? {
        #if os(macOS)
        guard let data = NSPasteboard.general
            .data(forType: .init(TransactionClipboard.pasteboardType)) else { return nil }
        #else
        guard let data = stored else { return nil }
        #endif
        return try? JSONDecoder().decode(TransactionClipboard.self, from: data)
    }

    /// Whether there is a transaction to paste.
    public static var hasTransaction: Bool { read() != nil }

    #if !os(macOS)
    /// iOS has no equivalent of a typed pasteboard entry worth the trouble here,
    /// so the clipboard lives for as long as the process does.
    private nonisolated(unsafe) static var stored: Data?
    #endif

    /// What a copied transaction looks like as text.
    static func describe(_ clipboard: TransactionClipboard) -> String {
        let date = AppDateFormat.current.string(clipboard.datePosted)
        let legs = clipboard.legs
            .map { "  \($0.accountFullName)  \($0.value)" }
            .joined(separator: "\n")
        return "\(date)  \(clipboard.transactionDescription)\n\(legs)"
    }
}

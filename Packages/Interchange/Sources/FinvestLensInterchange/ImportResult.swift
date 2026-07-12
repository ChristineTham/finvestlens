//
//  ImportResult.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// Counts, warnings, and integrity findings from an import (`FR-IMP-07`).
public struct ImportSummary: Sendable {
    public var commodityCount = 0
    public var accountCount = 0
    public var transactionCount = 0
    public var splitCount = 0
    public var priceCount = 0
    /// Non-fatal issues (synthesised commodities, skipped slots, etc.).
    public var warnings: [String] = []
    /// Structural issues found by ``Scrub`` after import (`FR-IMP-08`).
    public var scrubIssues: [Scrub.Issue] = []

    /// `true` when the import produced a structurally clean book.
    public var isClean: Bool { scrubIssues.isEmpty }
}

/// The outcome of importing a GnuCash file.
public struct ImportResult {
    /// The imported book (the in-memory source of truth).
    public let book: Book
    /// Counts, warnings, and integrity findings.
    public let summary: ImportSummary
}

/// Errors that abort an import.
public enum ImportError: Error, Equatable {
    case emptyData
    case malformedXML(String)
    case noBook
}

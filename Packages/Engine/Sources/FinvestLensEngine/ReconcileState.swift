//
//  ReconcileState.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

/// The reconciliation state of a ``Split``, matching GnuCash's single-character
/// codes used in the XML format.
public enum ReconcileState: String, Codable, Sendable, CaseIterable {
    /// Not reconciled (`n`).
    case notReconciled = "n"
    /// Cleared — seen on a statement but not yet reconciled (`c`).
    case cleared = "c"
    /// Reconciled (`y`).
    case reconciled = "y"
    /// Frozen (`f`).
    case frozen = "f"
    /// Voided (`v`).
    case voided = "v"
}

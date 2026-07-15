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

    /// GnuCash's name for the state, for anywhere it has to be read rather than
    /// abbreviated to its letter.
    public var label: String {
        switch self {
        case .notReconciled: "Not Reconciled"
        case .cleared: "Cleared"
        case .reconciled: "Reconciled"
        case .frozen: "Frozen"
        case .voided: "Voided"
        }
    }

    /// The states a register can set directly.
    ///
    /// Voided is left out: it is not a flag but an operation — voiding rewrites
    /// the transaction and keeps what it was worth, and undoing it is Unvoid,
    /// not "set the letter back". Letting a picker assign `v` was the shape of
    /// the bug where a stray click un-voided a transaction one split at a time.
    public static let settableInRegister: [ReconcileState] =
        [.notReconciled, .cleared, .reconciled, .frozen]
}

//
//  AutoClear.swift
//  FinvestLens — Engine
//
//  A port of GnuCash's `app-utils/gnc-autoclear.c` (`FR-REC-03`).
//
//  You have a statement balance and a pile of uncleared transactions. Which of
//  them add up to it? That is subset-sum, and the reason it is worth porting
//  rather than approximating is the part people get wrong: an answer is only
//  useful if it is the *only* answer. If two different sets of transactions both
//  reach the statement balance, picking one and clearing it would be a guess
//  about someone's money, and a plausible-looking one. GnuCash refuses, and so
//  does this.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Finds which uncleared splits add up to a statement balance.
public enum AutoClear {

    /// Why an auto-clear could not be done.
    public enum Failure: Error, Equatable {
        /// The account is already at the balance asked for.
        case alreadyAtTarget
        /// Nothing is uncleared, so there is nothing to work with.
        case nothingUncleared
        /// No subset of the uncleared splits reaches the balance.
        case unreachable
        /// More than one subset reaches it. The whole point of the port: two
        /// answers is not an answer.
        case ambiguous
        /// The search was called off before it ate the machine. Not GnuCash's
        /// limit — see ``Limits``.
        case tooComplex
    }

    /// Guards on the search, chosen here rather than ported.
    ///
    /// Subset-sum is exponential in the worst case: every split can double the
    /// number of reachable sums, so a full statement's worth would run until the
    /// machine gave out. GnuCash caps it too, and the point of a cap is to say
    /// "no" quickly rather than to be exactly this number. These are sized for
    /// the job auto-clear is actually for — a statement's uncleared tail — and
    /// the failure they raise is reported, not swallowed.
    public enum Limits {
        /// Uncleared splits considered. A statement with more than this is not
        /// the case this solves.
        public static let splits = 200
        /// Distinct reachable sums held at once.
        public static let reachableSums = 200_000
    }

    /// A sum's provenance: exactly one subset reaches it, or more than one does.
    private enum Reach {
        case unique([Split])
        case multiple
    }

    /// The splits that must be cleared for `account` to reach `targetBalance`.
    ///
    /// Only `n` splits are candidates: `c` and `y` already count toward the
    /// cleared balance, so their amounts come off the target rather than being
    /// something to choose. That is GnuCash's rule and it is the one that makes
    /// the arithmetic line up with the reconcile window's Cleared figure.
    ///
    /// Amounts are compared in the account's minor units — cents, not dollars —
    /// so the sums are exact integers and can be hashed. Decimal is exact but
    /// `1.10 + 2.20` is not a hash key you want to depend on.
    public static func splitsToClear(in account: Account, of book: Book,
                                     targetBalance: Decimal) throws -> [Split] {
        let all = book.splits(for: account).filter { $0.reconcileState != .voided }
        let uncleared = all.filter { $0.reconcileState == .notReconciled }
        guard !uncleared.isEmpty else { throw Failure.nothingUncleared }
        guard uncleared.count <= Limits.splits else { throw Failure.tooComplex }

        let fraction = max(account.commodity.smallestFraction, 1)
        let cleared = all.filter { $0.reconcileState != .notReconciled }
            .reduce(Decimal(0)) { $0 + $1.quantity }
        let target = minorUnits(targetBalance - cleared, fraction: fraction)

        guard target != 0 else { throw Failure.alreadyAtTarget }

        // GnuCash's "sack": every sum reachable so far, and the one subset that
        // reaches it — or a mark saying more than one does. Growing it a split
        // at a time is what lets ambiguity be spotted as it appears, instead of
        // by enumerating subsets and finding two at the end.
        var sack: [Int64: Reach] = [:]
        for split in uncleared {
            let value = minorUnits(split.quantity, fraction: fraction)
            var additions: [Int64: Reach] = [:]

            func offer(_ sum: Int64, _ reach: Reach) {
                // Reachable already — by an earlier subset, or by another one
                // being added in this same round — means reachable two ways.
                if sack[sum] != nil || additions[sum] != nil {
                    additions[sum] = .multiple
                } else {
                    additions[sum] = reach
                }
            }

            offer(value, .unique([split]))
            for (sum, reach) in sack {
                switch reach {
                case .unique(let subset): offer(sum + value, .unique(subset + [split]))
                // Two ways to reach a sum stay two ways once extended.
                case .multiple: offer(sum + value, .multiple)
                }
            }

            for (sum, reach) in additions { sack[sum] = reach }
            guard sack.count <= Limits.reachableSums else { throw Failure.tooComplex }
        }

        switch sack[target] {
        case .unique(let splits): return splits
        case .multiple: throw Failure.ambiguous
        case nil: throw Failure.unreachable
        }
    }

    /// A money amount as a whole number of the commodity's minor units.
    ///
    /// Rounded, not truncated, and rounded at the fraction the amount is already
    /// stored at — so this is reading the number the book holds, not altering it.
    private static func minorUnits(_ amount: Decimal, fraction: Int) -> Int64 {
        var scaled = amount * Decimal(fraction)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).int64Value
    }
}

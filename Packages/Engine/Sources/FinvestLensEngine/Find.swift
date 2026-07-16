//
//  Find.swift
//  FinvestLens — Engine
//
//  A structured query over a book, modelled on GnuCash's Find Transaction.
//
//  The dialog GnuCash shows is headed **Split Search**, and that is the whole
//  design. A criterion is tested against a *split*, not a transaction: "Account
//  is CDIA and Reconcile is Reconciled" means one split that is both, not a
//  transaction with a CDIA split and, elsewhere, some unrelated reconciled one.
//  Evaluating per transaction gives the wrong answer on exactly the multi-split
//  transactions people search for — a share buy, a split payslip.
//
//  Criteria that belong to the transaction (description, notes, number, date)
//  are read through the split's parent, so they compose with split criteria in
//  the same test.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

// MARK: - Comparators

/// How a text criterion compares (GnuCash: contains / does not contain, and the
/// exact-match pair), with case sensitivity carried alongside.
public enum TextComparator: String, CaseIterable, Sendable, Hashable, Codable {
    case contains
    case doesNotContain
    case matchesExactly
    case doesNotMatchExactly

    public var label: String {
        switch self {
        case .contains: "contains"
        case .doesNotContain: "does not contain"
        case .matchesExactly: "matches exactly"
        case .doesNotMatchExactly: "does not match exactly"
        }
    }
}

/// GnuCash's six date comparators, verified against its Find dialog.
public enum DateComparator: String, CaseIterable, Sendable, Hashable, Codable {
    case isBefore
    case isBeforeOrOn
    case isOn
    case isNotOn
    case isAfter
    case isOnOrAfter

    public var label: String {
        switch self {
        case .isBefore: "is before"
        case .isBeforeOrOn: "is before or on"
        case .isOn: "is on"
        case .isNotOn: "is not on"
        case .isAfter: "is after"
        case .isOnOrAfter: "is on or after"
        }
    }
}

public enum NumberComparator: String, CaseIterable, Sendable, Hashable, Codable {
    case lessThan
    case lessThanOrEqual
    case equalTo
    case notEqualTo
    case greaterThanOrEqual
    case greaterThan

    public var label: String {
        switch self {
        case .lessThan: "is less than"
        case .lessThanOrEqual: "is less than or equal to"
        case .equalTo: "equals"
        case .notEqualTo: "does not equal"
        case .greaterThanOrEqual: "is greater than or equal to"
        case .greaterThan: "is greater than"
        }
    }
}

/// Membership, for the criteria whose value is a set.
public enum SetComparator: String, CaseIterable, Sendable, Hashable, Codable {
    case isOneOf
    case isNotOneOf

    /// Reads next to a row of checkboxes, as GnuCash words the reconcile row.
    public var label: String {
        switch self {
        case .isOneOf: "is"
        case .isNotOneOf: "is not"
        }
    }

    /// GnuCash words the account row differently, and better: the set is a list
    /// of accounts, so "is" would read as though only one could be chosen.
    public var accountLabel: String {
        switch self {
        case .isOneOf: "matches any account"
        case .isNotOneOf: "matches no accounts"
        }
    }
}

// MARK: - Fields

/// The text fields a query can test. `descriptionNotesOrMemo` is GnuCash's
/// combined field, and is the one most people actually want.
public enum FindTextField: String, CaseIterable, Sendable, Hashable, Codable {
    case description
    case notes
    case memo
    case descriptionNotesOrMemo
    case number
    case action

    public var label: String {
        switch self {
        case .description: "Description"
        case .notes: "Notes"
        case .memo: "Memo"
        case .descriptionNotesOrMemo: "Description, Notes, or Memo"
        case .number: "Number"
        case .action: "Action"
        }
    }
}

public enum FindDateField: String, CaseIterable, Sendable, Hashable, Codable {
    case posted
    case reconciled

    public var label: String {
        switch self {
        case .posted: "Date Posted"
        case .reconciled: "Reconciled Date"
        }
    }
}

/// The numeric fields. `shares` is the split quantity and `sharePrice` is
/// value ÷ quantity — the same decomposition the register uses.
public enum FindNumberField: String, CaseIterable, Sendable, Hashable, Codable {
    case value
    case shares
    case sharePrice

    public var label: String {
        switch self {
        case .value: "Value"
        case .shares: "Shares"
        case .sharePrice: "Share Price"
        }
    }
}

// MARK: - Criterion

/// One test. The associated values make invalid combinations unrepresentable:
/// there is no way to build a date criterion holding a text comparator.
///
/// `Codable`, because a query someone took sixteen criteria to build is a query
/// they will want back — saved find queries serialise these into the book.
public enum FindTest: Sendable, Hashable, Codable {
    case text(FindTextField, TextComparator, String, matchCase: Bool)
    case date(FindDateField, DateComparator, Date)
    case number(FindNumberField, NumberComparator, Decimal)
    case reconcile(SetComparator, Set<ReconcileState>)
    case account(SetComparator, Set<GncGUID>)
    /// The transaction posts to **every** one of these accounts — GnuCash's
    /// "All Accounts" row, distinct from `account`, which asks about the one
    /// split. "CDIA and Brokerage" here means a transfer between them.
    case allAccounts(Set<GncGUID>)
    case balanced(Bool)
    /// GnuCash's "Closing Entries": the transactions Close Book writes, marked
    /// with the `book_closing` slot. Mostly used negated, to keep year-end
    /// bookkeeping out of a search over real activity.
    case closing(Bool)
}

public struct FindCriterion: Identifiable, Sendable, Hashable, Codable {
    public var id: UUID
    public var test: FindTest

    public init(id: UUID = UUID(), test: FindTest) {
        self.id = id
        self.test = test
    }
}

/// A whole query: the criteria, and whether a split must satisfy all of them or
/// any of them (GnuCash's "Search for items where [all|any] criteria are met").
public struct FindQuery: Sendable, Hashable, Codable {
    public var criteria: [FindCriterion]
    public var matchAll: Bool

    public init(criteria: [FindCriterion] = [], matchAll: Bool = true) {
        self.criteria = criteria
        self.matchAll = matchAll
    }

    /// A query with no criteria matches nothing. It is not "match everything":
    /// an empty Find dialog should return an empty register, not all 46,553
    /// transactions.
    public var isEmpty: Bool { criteria.isEmpty }
}

// MARK: - Evaluation

public extension FindQuery {

    /// Whether `split` satisfies the query.
    func matches(_ split: Split) -> Bool {
        guard !criteria.isEmpty else { return false }
        return matchAll
            ? criteria.allSatisfy { $0.test.matches(split) }
            : criteria.contains { $0.test.matches(split) }
    }
}

public extension FindTest {

    func matches(_ split: Split) -> Bool {
        switch self {
        case .text(let field, let comparator, let needle, let matchCase):
            return Self.matchText(field, comparator, needle, matchCase, split)
        case .date(let field, let comparator, let value):
            return Self.matchDate(field, comparator, value, split)
        case .number(let field, let comparator, let value):
            return Self.matchNumber(field, comparator, value, split)
        case .reconcile(let comparator, let states):
            let hit = states.contains(split.reconcileState)
            return comparator == .isOneOf ? hit : !hit
        case .account(let comparator, let ids):
            guard let id = split.account?.guid else { return comparator == .isNotOneOf }
            let hit = ids.contains(id)
            return comparator == .isOneOf ? hit : !hit
        case .allAccounts(let ids):
            // A transaction-level test read through the split's parent, like
            // description or date: does the transaction post to every chosen
            // account? An empty set is vacuously true of anything, which as a
            // search means nothing — treat it as no match, same as the empty
            // query.
            guard !ids.isEmpty, let txn = split.transaction else { return false }
            let posted = Set(txn.splits.compactMap { $0.account?.guid })
            return ids.isSubset(of: posted)
        case .balanced(let want):
            guard let txn = split.transaction else { return false }
            return txn.isBalanced == want
        case .closing(let want):
            return (split.transaction.map(Self.isClosing) ?? false) == want
        }
    }

    /// Whether a transaction is a book-closing entry — GnuCash marks them with
    /// the `book_closing` slot, which the importer carries through. Any value in
    /// the slot counts: GnuCash writes an int 1, but the presence is the marker.
    static func isClosing(_ txn: Transaction) -> Bool {
        switch txn.kvp["book_closing"] {
        case nil: false
        case .int64(let v): v != 0
        case .string(let s): s != "0" && !s.isEmpty
        default: true
        }
    }

    // MARK: Text

    private static func matchText(_ field: FindTextField, _ comparator: TextComparator,
                                  _ needle: String, _ matchCase: Bool, _ split: Split) -> Bool {
        let haystacks = texts(for: field, split)
        let hit: Bool
        switch comparator {
        case .contains, .doesNotContain:
            hit = haystacks.contains { compare($0, contains: needle, matchCase: matchCase) }
        case .matchesExactly, .doesNotMatchExactly:
            hit = haystacks.contains { equal($0, needle, matchCase: matchCase) }
        }
        switch comparator {
        case .contains, .matchesExactly: return hit
        case .doesNotContain, .doesNotMatchExactly: return !hit
        }
    }

    /// The strings a text field reads. `descriptionNotesOrMemo` returns three,
    /// so "contains" is any-of and "does not contain" is none-of — which falls
    /// out of negating the any-of result rather than needing its own rule.
    private static func texts(for field: FindTextField, _ split: Split) -> [String] {
        let txn = split.transaction
        switch field {
        case .description: return [txn?.transactionDescription ?? ""]
        case .notes: return [txn?.notes ?? ""]
        case .memo: return [split.memo]
        case .descriptionNotesOrMemo:
            return [txn?.transactionDescription ?? "", txn?.notes ?? "", split.memo]
        case .number: return [txn?.number ?? ""]
        case .action: return [split.action]
        }
    }

    private static func compare(_ haystack: String, contains needle: String, matchCase: Bool) -> Bool {
        guard !needle.isEmpty else { return true }
        return matchCase
            ? haystack.contains(needle)
            : haystack.range(of: needle, options: .caseInsensitive) != nil
    }

    private static func equal(_ haystack: String, _ needle: String, matchCase: Bool) -> Bool {
        matchCase ? haystack == needle : haystack.lowercased() == needle.lowercased()
    }

    // MARK: Dates

    /// Dates compare by **day**, not instant: "is on 5 Apr" must match a
    /// posting stamped any time that day.
    private static func matchDate(_ field: FindDateField, _ comparator: DateComparator,
                                  _ value: Date, _ split: Split) -> Bool {
        let subject: Date?
        switch field {
        case .posted: subject = split.transaction?.datePosted
        case .reconciled: subject = split.reconcileDate
        }
        guard let subject else { return false }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let a = calendar.startOfDay(for: subject)
        let b = calendar.startOfDay(for: value)
        switch comparator {
        case .isBefore: return a < b
        case .isBeforeOrOn: return a <= b
        case .isOn: return a == b
        case .isNotOn: return a != b
        case .isAfter: return a > b
        case .isOnOrAfter: return a >= b
        }
    }

    // MARK: Numbers

    private static func matchNumber(_ field: FindNumberField, _ comparator: NumberComparator,
                                    _ value: Decimal, _ split: Split) -> Bool {
        guard let subject = number(for: field, split) else { return false }
        switch comparator {
        case .lessThan: return subject < value
        case .lessThanOrEqual: return subject <= value
        case .equalTo: return subject == value
        case .notEqualTo: return subject != value
        case .greaterThanOrEqual: return subject >= value
        case .greaterThan: return subject > value
        }
    }

    private static func number(for field: FindNumberField, _ split: Split) -> Decimal? {
        switch field {
        case .value: return split.value
        case .shares: return split.quantity
        case .sharePrice:
            // Undefined for a zero quantity rather than zero: a cash posting has
            // no share price, and saying "price = 0" would match `< 1`.
            guard split.quantity != 0 else { return nil }
            return split.value / split.quantity
        }
    }
}

public extension Book {

    /// Splits matching `query`, in book order.
    ///
    /// This is the primitive; callers that want transactions roll these up
    /// themselves, keeping the matched split so they know which register the
    /// hit actually lives in.
    func splitsMatching(_ query: FindQuery) -> [Split] {
        guard !query.isEmpty else { return [] }
        return transactions.flatMap { txn in
            txn.splits.filter { query.matches($0) }
        }
    }
}

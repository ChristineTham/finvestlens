//
//  Statements.swift
//  FinvestLens — FeatureUI
//
//  The statement presentation layer (docs/report-redesign.md §3.1): turns the
//  engine's verified flat report lines into an annual-report statement — a
//  face of judgement-called captions, and notes carrying the detail.
//
//  The engine stays the single source of arithmetic. This layer only
//  *arranges*: it groups lines by the user's own account tree, orders assets
//  by liquidity and liabilities by maturity (ASC 274 personal-statement
//  presentation), collapses trivial chains, folds immaterial captions into
//  "Other", and pushes detail into numbered notes whose totals tie back to
//  the face. Identity tests enforce that no dollar moves.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensReports

// MARK: - The statement value

/// What a row on the face of a statement is doing.
enum StatementRole: Sendable {
    case line        // a caption
    case childLine   // an indented face child (small sections, rule 4)
    case subtotal    // a section subtotal (single rule above)
    case grandTotal  // the statement's closing figure (double rule below)
}

/// One row on the face of a statement.
struct StatementItem: Identifiable, Sendable {
    let id = UUID()
    var caption: String
    var noteRef: Int?
    /// Aligned with ``Statement/columns`` — `nil` renders blank.
    var amounts: [Decimal?]
    var depth = 0
    var role: StatementRole = .line
}

/// One section of the face (Assets, Income, …).
struct StatementSection: Identifiable, Sendable {
    var id: String { title }
    var title: String
    var items: [StatementItem]
    var totalLabel: String
    var totalAmounts: [Decimal?]
}

/// A detail row inside a note — the full hierarchy down to leaf accounts.
struct StatementNoteRow: Identifiable, Sendable {
    let id = UUID()
    var label: String
    var depth: Int
    var amounts: [Decimal?]
}

/// A numbered note. Its total ties to the face line that references it.
struct StatementNote: Identifiable, Sendable {
    var id: Int { number }
    var number: Int
    var title: String
    /// Prose lines (Note 1 — basis of preparation). Empty for detail notes.
    var body: [String] = []
    var rows: [StatementNoteRow] = []
    var totalLabel: String?
    var totalAmounts: [Decimal?] = []
}

/// A complete statement: masthead, face, notes.
struct Statement: Sendable {
    var title: String
    var entityName: String
    var periodLabel: String
    var unitsLabel: String
    var currencyCode: String
    /// Column headers, current first ("2026", "2025").
    var columns: [String]
    var sections: [StatementSection]
    /// The closing figure after the sections (Net worth / Net surplus).
    var grandTotal: (label: String, amounts: [Decimal?])?
    var notes: [StatementNote]
}

// MARK: - Builder

/// Builds statements from engine reports + the account tree. Pure given its
/// inputs — the judgement rules live here and are unit-tested.
@MainActor
struct StatementBuilder {
    let book: Book

    /// Face captions per section are capped here; the rest folds into Other.
    static let maxFaceCaptions = 10
    /// A caption below this share of its section's absolute total folds into
    /// Other (unless it was material in the prior period).
    static let materialityShare = Decimal(0.02)
    /// A caption whose subtree has at most this many amount-bearing accounts
    /// shows its children on the face instead of a note (rule 4).
    static let smallSectionLeaves = 3

    // MARK: Amount tree

    /// A node of the presentation tree: an account with its own line amounts
    /// (if any) and the children that carry amounts.
    final class Node {
        let name: String
        let fullName: String
        let type: AccountType?
        var own: [Decimal?]
        var children: [Node]

        init(name: String, fullName: String, type: AccountType?,
             own: [Decimal?], children: [Node] = []) {
            self.name = name
            self.fullName = fullName
            self.type = type
            self.own = own
            self.children = children
        }

        var total: [Decimal?] {
            var sums = own
            for child in children {
                for index in child.total.indices {
                    if let value = child.total[index] {
                        sums[index] = (sums[index] ?? 0) + value
                    }
                }
            }
            return sums
        }

        /// Amount-bearing accounts in the subtree (self included when it has
        /// its own line).
        var bearingCount: Int {
            (own.contains { $0 != nil && $0 != 0 } ? 1 : 0)
                + children.reduce(0) { $0 + $1.bearingCount }
        }

        /// Sum of |amount| per account type over the subtree — the dominant
        /// type decides the caption's liquidity class.
        func typeWeights(into weights: inout [AccountType: Decimal]) {
            if let type, let value = own.first ?? nil {
                weights[type, default: 0] += abs(value)
            }
            for child in children { child.typeWeights(into: &weights) }
        }
    }

    /// Builds the presentation tree for one statement section from engine
    /// lines: amounts attach to their accounts, ancestors materialise as
    /// containers, and the roots returned are the face-caption candidates
    /// (the highest grouping below the top-level category account).
    ///
    /// `columnCount` is the number of amount columns; `lineSets` supplies one
    /// `[ReportLine]` per column (current first, prior after).
    func captionForest(lineSets: [[ReportLine]]) -> [Node] {
        let columnCount = lineSets.count
        // GUID → per-column amount.
        var amounts: [GncGUID: [Decimal?]] = [:]
        var orphanLines: [(name: String, amounts: [Decimal?])] = []
        for (column, lines) in lineSets.enumerated() {
            for line in lines {
                if book.account(with: line.id) != nil {
                    var slot = amounts[line.id] ?? Array(repeating: nil, count: columnCount)
                    slot[column] = (slot[column] ?? 0) + line.amount
                    amounts[line.id] = slot
                } else {
                    // Synthetic lines (Unrealised FX) have no account — they
                    // become their own caption, merged across columns by name.
                    if let index = orphanLines.firstIndex(where: { $0.name == line.name }) {
                        orphanLines[index].amounts[column] = (orphanLines[index].amounts[column] ?? 0) + line.amount
                    } else {
                        var slot: [Decimal?] = Array(repeating: nil, count: columnCount)
                        slot[column] = line.amount
                        orphanLines.append((line.name, slot))
                    }
                }
            }
        }

        // Recursive projection of the real account tree onto the line set.
        func project(_ account: Account) -> Node? {
            let own = amounts[account.guid]
            let kids = account.children.compactMap(project)
            if own == nil && kids.isEmpty { return nil }
            return Node(name: Self.displayName(for: account),
                        fullName: account.fullName,
                        type: account.type,
                        own: own ?? Array(repeating: nil, count: columnCount),
                        children: kids)
        }

        var roots: [Node] = []
        for topLevel in book.rootAccount.children {
            guard let node = project(topLevel) else { continue }
            // The top-level account is the category container ("Assets",
            // "Income"); its children are the captions. A top-level account
            // that itself carries the amounts (flat book, or a stray
            // top-level posting account) is its own caption.
            if node.children.isEmpty || node.own.contains(where: { ($0 ?? 0) != 0 }) {
                roots.append(node)
            } else {
                roots.append(contentsOf: node.children)
            }
        }
        roots.append(contentsOf: orphanLines.map {
            Node(name: $0.name, fullName: $0.name, type: nil, own: $0.amounts)
        })
        return roots.map(Self.collapsed)
    }

    /// Plain-language caption for accounts whose bookkeeping names would look
    /// wrong on a statement (rule 8b): `Imbalance-AUD` / `Orphan-…` read as
    /// "Uncategorised".
    static func displayName(for account: Account) -> String {
        if account.isImbalanceOrOrphan { return "Uncategorised" }
        return account.name
    }

    /// Rule 3 — collapse trivial chains, bottom-up. A container with exactly
    /// one child and no amounts of its own merges with that child; the name
    /// kept is the more specific of the two (generic leaf terms like
    /// "Distribution" or "Dividend" lose to a named parent).
    static let genericLeafNames: Set<String> = [
        "distribution", "distributions", "dividend", "dividends", "interest",
        "income", "expense", "expenses", "general", "other", "misc",
        "miscellaneous", "main", "default",
    ]

    static func collapsed(_ node: Node) -> Node {
        node.children = node.children.map(collapsed)
        let hasOwn = node.own.contains { ($0 ?? 0) != 0 }
        if !hasOwn, node.children.count == 1, let only = node.children.first {
            let keepParentName = genericLeafNames.contains(only.name.lowercased())
                && !genericLeafNames.contains(node.name.lowercased())
            return Node(name: keepParentName ? node.name : only.name,
                        fullName: node.fullName,
                        type: only.type ?? node.type,
                        own: only.own,
                        children: only.children)
        }
        return node
    }

    // MARK: Ordering (rule 2)

    /// ASC 274: assets in order of liquidity.
    static func liquidityClass(_ type: AccountType?) -> Int {
        switch type {
        case .bank, .cash: 0
        case .stock, .mutualFund: 1
        case .receivable: 2
        default: 3
        }
    }

    /// Liabilities in order of maturity (credit revolvers first).
    static func maturityClass(_ type: AccountType?) -> Int {
        switch type {
        case .credit: 0
        case .payable: 1
        default: 2
        }
    }

    enum SectionOrdering {
        case liquidity, maturity, magnitude, none
    }

    static func sort(_ nodes: [Node], by ordering: SectionOrdering) -> [Node] {
        func dominantType(_ node: Node) -> AccountType? {
            var weights: [AccountType: Decimal] = [:]
            node.typeWeights(into: &weights)
            return weights.max { $0.value < $1.value }?.key
        }
        func magnitude(_ node: Node) -> Decimal {
            abs((node.total.first ?? nil) ?? 0)
        }
        func signedValue(_ node: Node) -> Decimal {
            (node.total.first ?? nil) ?? 0
        }
        // Integrity balances (Uncategorised) stay visible but never lead a
        // statement — they order after every real caption.
        func integrityClass(_ node: Node) -> Int {
            node.name == "Uncategorised" ? 1 : 0
        }
        // Within a liquidity/maturity class, positive balances lead
        // (largest first) and negatives trail — an annual report opens a
        // section with its strongest lines, not its oddities.
        func classOrder(_ a: Node, _ b: Node, _ classOf: (AccountType?) -> Int) -> Bool {
            let ia = integrityClass(a), ib = integrityClass(b)
            if ia != ib { return ia < ib }
            let ca = classOf(dominantType(a)), cb = classOf(dominantType(b))
            if ca != cb { return ca < cb }
            let va = signedValue(a), vb = signedValue(b)
            if (va >= 0) != (vb >= 0) { return va >= 0 }
            return magnitude(a) > magnitude(b)
        }
        switch ordering {
        case .liquidity:
            return nodes.sorted { classOrder($0, $1, liquidityClass) }
        case .maturity:
            return nodes.sorted { classOrder($0, $1, maturityClass) }
        case .magnitude:
            return nodes.sorted {
                if integrityClass($0) != integrityClass($1) {
                    return integrityClass($0) < integrityClass($1)
                }
                return magnitude($0) > magnitude($1)
            }
        case .none:
            return nodes
        }
    }

    // MARK: Section assembly (rules 4–6)

    struct BuiltSection {
        var section: StatementSection
        var notes: [StatementNote]   // numbered later
    }

    /// Assembles one face section from its caption forest: materiality
    /// folding, face children for small captions, note detail for the rest.
    /// `protected` captions never fold into Other — IAS 1's minimum line
    /// items (cash and equivalents) and integrity signals (Uncategorised)
    /// stay on the face however small they are.
    func buildSection(title: String, totalLabel: String,
                      forest: [Node], ordering: SectionOrdering,
                      columnCount: Int,
                      protected: (Node) -> Bool = { _ in false }) -> BuiltSection {
        let ordered = Self.sort(forest, by: ordering)

        // Section totals per column (before any folding — folding conserves).
        var sectionTotals: [Decimal?] = Array(repeating: nil, count: columnCount)
        for node in ordered {
            for (index, value) in node.total.enumerated() where value != nil {
                sectionTotals[index] = (sectionTotals[index] ?? 0) + value!
            }
        }

        // Rule 5 — materiality: a caption folds into Other when it is small
        // in *every* column (prior materiality keeps a line on the face).
        let thresholds = sectionTotals.map { abs($0 ?? 0) * Self.materialityShare }
        func isMaterial(_ node: Node) -> Bool {
            if protected(node) { return true }
            for (index, value) in node.total.enumerated() {
                if abs(value ?? 0) >= thresholds[index], (value ?? 0) != 0 { return true }
            }
            return false
        }
        var face = ordered.filter(isMaterial)
        var folded = ordered.filter { !isMaterial($0) }
        // Cap the face; overflow joins Other from the small end — but never
        // a protected caption.
        if face.count > Self.maxFaceCaptions {
            let overflow = face.suffix(from: Self.maxFaceCaptions).filter { !protected($0) }
            folded.append(contentsOf: overflow)
            face = face.filter { candidate in
                !overflow.contains(where: { $0 === candidate })
            }
        }

        var items: [StatementItem] = []
        var notes: [StatementNote] = []

        func noteRows(_ node: Node, depth: Int, into rows: inout [StatementNoteRow]) {
            let ownOnly = node.children.isEmpty
            rows.append(StatementNoteRow(label: node.name, depth: depth,
                                         amounts: ownOnly ? node.own : node.total))
            // A container that also has its own postings gets a "(direct)"
            // detail row so the note still adds up visibly.
            if !node.children.isEmpty, node.own.contains(where: { ($0 ?? 0) != 0 }) {
                rows.append(StatementNoteRow(label: "\(node.name) (direct)",
                                             depth: depth + 1, amounts: node.own))
            }
            for child in Self.sort(node.children, by: .magnitude) {
                noteRows(child, depth: depth + 1, into: &rows)
            }
        }

        for node in face {
            let leaves = node.bearingCount
            if node.children.isEmpty || leaves <= Self.smallSectionLeaves {
                // Rule 4 — small captions live entirely on the face.
                items.append(StatementItem(caption: node.name, noteRef: nil,
                                           amounts: node.total, role: .line))
                for child in Self.sort(node.children, by: .magnitude) {
                    items.append(StatementItem(caption: child.name, noteRef: nil,
                                               amounts: child.total, depth: 1,
                                               role: .childLine))
                }
            } else {
                // Rule 6 — the detail moves to a note.
                var rows: [StatementNoteRow] = []
                for child in Self.sort(node.children, by: .magnitude) {
                    noteRows(child, depth: 0, into: &rows)
                }
                if node.own.contains(where: { ($0 ?? 0) != 0 }) {
                    rows.append(StatementNoteRow(label: "\(node.name) (direct)",
                                                 depth: 0, amounts: node.own))
                }
                let note = StatementNote(number: 0, title: node.name,
                                         rows: rows,
                                         totalLabel: "Total \(node.name)",
                                         totalAmounts: node.total)
                notes.append(note)
                items.append(StatementItem(caption: node.name,
                                           noteRef: notes.count - 1,  // placeholder index
                                           amounts: node.total, role: .line))
            }
        }

        if !folded.isEmpty {
            var otherTotals: [Decimal?] = Array(repeating: nil, count: columnCount)
            for node in folded {
                for (index, value) in node.total.enumerated() where value != nil {
                    otherTotals[index] = (otherTotals[index] ?? 0) + value!
                }
            }
            var rows: [StatementNoteRow] = []
            for node in Self.sort(folded, by: .magnitude) {
                noteRows(node, depth: 0, into: &rows)
            }
            let note = StatementNote(number: 0, title: "Other \(title.lowercased())",
                                     rows: rows,
                                     totalLabel: "Total other \(title.lowercased())",
                                     totalAmounts: otherTotals)
            notes.append(note)
            items.append(StatementItem(caption: "Other \(title.lowercased())",
                                       noteRef: notes.count - 1,
                                       amounts: otherTotals, role: .line))
        }

        let section = StatementSection(title: title, items: items,
                                       totalLabel: totalLabel,
                                       totalAmounts: sectionTotals)
        return BuiltSection(section: section, notes: notes)
    }

    // MARK: Statements

    /// Resolves per-section placeholder note indices into sequential note
    /// numbers (Note 1 = basis of preparation), in face order.
    private func numberNotes(sections: [BuiltSection],
                             basis: StatementNote) -> ([StatementSection], [StatementNote]) {
        var notes: [StatementNote] = [basis]
        var faces: [StatementSection] = []
        for built in sections {
            var face = built.section
            for index in face.items.indices {
                if let local = face.items[index].noteRef {
                    var note = built.notes[local]
                    note.number = notes.count + 1
                    notes.append(note)
                    face.items[index].noteRef = note.number
                }
            }
            faces.append(face)
        }
        return (faces, notes)
    }

    private func basisNote(asOf: Date, comparativeLabel: String?) -> StatementNote {
        var body = [
            "Prepared from the accounting records of the book on an accrual basis.",
            "Assets are stated at estimated current value: securities at the most recent recorded market price, foreign-currency balances translated at the nearest recorded exchange rate.",
            "Amounts are presented in \(book.rootAccount.commodity.fullName.isEmpty ? book.rootAccount.commodity.mnemonic : book.rootAccount.commodity.fullName) and rounded to the nearest cent; negatives are shown in parentheses.",
        ]
        if let comparativeLabel {
            body.append("Comparative figures are presented for \(comparativeLabel).")
        }
        return StatementNote(number: 1, title: "Basis of preparation", body: body)
    }

    /// The Statement of Financial Position (ASC 274 personal presentation):
    /// assets by liquidity, liabilities by maturity, and Net worth as the
    /// closing figure — the equity composition moves to a note.
    func financialPosition(entityName: String,
                           current: BalanceSheet, currentLabel: String,
                           prior: BalanceSheet?, priorLabel: String?) -> Statement {
        let columnCount = prior == nil ? 1 : 2
        let columns = [currentLabel] + (priorLabel.map { [$0] } ?? [])

        let assetForest = captionForest(lineSets:
            [current.assets] + (prior.map { [$0.assets] } ?? []))
        let liabilityForest = captionForest(lineSets:
            [current.liabilities] + (prior.map { [$0.liabilities] } ?? []))

        // IAS 1 minimum line items: cash and equivalents never fold; an
        // Uncategorised balance is an integrity signal that must stay visible.
        func protectedAsset(_ node: Node) -> Bool {
            if node.name == "Uncategorised" { return true }
            var weights: [AccountType: Decimal] = [:]
            node.typeWeights(into: &weights)
            let dominant = weights.max { $0.value < $1.value }?.key
            return Self.liquidityClass(dominant) == 0
        }
        var assets = buildSection(title: "Assets", totalLabel: "Total assets",
                                  forest: assetForest, ordering: .liquidity,
                                  columnCount: columnCount,
                                  protected: protectedAsset)
        var liabilities = buildSection(title: "Liabilities", totalLabel: "Total liabilities",
                                       forest: liabilityForest, ordering: .maturity,
                                       columnCount: columnCount,
                                       protected: { $0.name == "Uncategorised" })
        // The section totals come from the engine's own figures — the forest
        // must agree (identity-tested), but the engine's number is the truth.
        assets.section.totalAmounts = [current.totalAssets, prior?.totalAssets]
            .prefix(columnCount).map { $0 }
        liabilities.section.totalAmounts = [current.totalLiabilities, prior?.totalLiabilities]
            .prefix(columnCount).map { $0 }

        let netWorth: [Decimal?] = columnCount == 2
            ? [current.totalAssets - current.totalLiabilities,
               (prior?.totalAssets ?? 0) - (prior?.totalLiabilities ?? 0)]
            : [current.totalAssets - current.totalLiabilities]

        var (faces, notes) = numberNotes(
            sections: [assets, liabilities],
            basis: basisNote(asOf: current.asOf, comparativeLabel: priorLabel))

        // Net-worth composition note: the equity view of the same figure.
        var equityRows: [StatementNoteRow] = current.equity.map {
            StatementNoteRow(label: $0.name, depth: 0,
                             amounts: columnCount == 2 ? [$0.amount, nil] : [$0.amount])
        }
        equityRows.append(StatementNoteRow(
            label: "Accumulated surplus (income less expenses to date)", depth: 0,
            amounts: columnCount == 2 ? [current.retainedEarnings, prior?.retainedEarnings]
                                      : [current.retainedEarnings]))
        // Multi-currency books: income converts at posting-date rates while
        // assets convert at current rates, so the equity view can differ
        // from A − L. The note reconciles with a translation line, exactly
        // as an annual report's translation reserve does.
        let currentResidual = (current.totalAssets - current.totalLiabilities) - current.totalEquity
        let priorResidual = prior.map { ($0.totalAssets - $0.totalLiabilities) - $0.totalEquity }
        if currentResidual != 0 || (priorResidual ?? 0) != 0 {
            equityRows.append(StatementNoteRow(
                label: "Currency translation and valuation differences", depth: 0,
                amounts: columnCount == 2 ? [currentResidual, priorResidual]
                                          : [currentResidual]))
        }
        let composition = StatementNote(
            number: notes.count + 1,
            title: "Composition of net worth",
            rows: equityRows,
            totalLabel: "Net worth",
            totalAmounts: netWorth)
        notes.append(composition)

        return Statement(
            title: "Statement of Financial Position",
            entityName: entityName,
            periodLabel: "As at \(currentLabel)",
            unitsLabel: unitsLabel(),
            currencyCode: current.currencyCode,
            columns: columns,
            sections: faces,
            grandTotal: ("Net worth (Note \(composition.number))", netWorth),
            notes: notes)
    }

    /// The Income Statement: income and expenses by the book's own groups,
    /// magnitude-ordered, closing at the net surplus.
    func incomeStatement(entityName: String,
                         current: IncomeStatement, currentLabel: String,
                         prior: IncomeStatement?, priorLabel: String?) -> Statement {
        let columnCount = prior == nil ? 1 : 2
        let columns = [currentLabel] + (priorLabel.map { [$0] } ?? [])

        let incomeForest = captionForest(lineSets:
            [current.income] + (prior.map { [$0.income] } ?? []))
        let expenseForest = captionForest(lineSets:
            [current.expenses] + (prior.map { [$0.expenses] } ?? []))

        var income = buildSection(title: "Income", totalLabel: "Total income",
                                  forest: incomeForest, ordering: .magnitude,
                                  columnCount: columnCount,
                                  protected: { $0.name == "Uncategorised" })
        var expenses = buildSection(title: "Expenses", totalLabel: "Total expenses",
                                    forest: expenseForest, ordering: .magnitude,
                                    columnCount: columnCount,
                                    protected: { $0.name == "Uncategorised" })
        income.section.totalAmounts = [current.totalIncome, prior?.totalIncome]
            .prefix(columnCount).map { $0 }
        expenses.section.totalAmounts = [current.totalExpenses, prior?.totalExpenses]
            .prefix(columnCount).map { $0 }

        let net: [Decimal?] = columnCount == 2
            ? [current.netIncome, prior?.netIncome]
            : [current.netIncome]

        let (faces, notes) = numberNotes(
            sections: [income, expenses],
            basis: basisNote(asOf: current.to, comparativeLabel: priorLabel))

        return Statement(
            title: "Income Statement",
            entityName: entityName,
            periodLabel: currentLabel,
            unitsLabel: unitsLabel(),
            currencyCode: current.currencyCode,
            columns: columns,
            sections: faces,
            grandTotal: ("Net surplus for the period", net),
            notes: notes)
    }

    /// The Statement of Changes in Net Worth (ASC 274's second statement):
    /// opening net worth, the period's surplus, and the valuation/FX movement
    /// derived as the balancing figure, closing at the period-end net worth.
    func changesInNetWorth(entityName: String,
                           opening: BalanceSheet, closing: BalanceSheet,
                           period: IncomeStatement,
                           currentLabel: String) -> Statement {
        let openingNet = opening.totalAssets - opening.totalLiabilities
        let closingNet = closing.totalAssets - closing.totalLiabilities
        // Everything the surplus doesn't explain is valuation movement:
        // market-price changes, FX translation, and opening-balance entries.
        let valuation = closingNet - openingNet - period.netIncome

        let rows: [StatementItem] = [
            StatementItem(caption: "Net worth at the beginning of the period",
                          amounts: [openingNet], role: .line),
            StatementItem(caption: "Net surplus for the period",
                          amounts: [period.netIncome], role: .line),
            StatementItem(caption: "Income", amounts: [period.totalIncome],
                          depth: 1, role: .childLine),
            StatementItem(caption: "Expenses", amounts: [-period.totalExpenses],
                          depth: 1, role: .childLine),
            StatementItem(caption: "Net valuation and currency movement",
                          amounts: [valuation], role: .line),
        ]
        let section = StatementSection(title: "Changes in net worth",
                                       items: rows,
                                       totalLabel: "Net worth at the end of the period",
                                       totalAmounts: [closingNet])

        let basis = basisNote(asOf: closing.asOf, comparativeLabel: nil)
        var valuationNote = StatementNote(
            number: 2, title: "Net valuation and currency movement",
            body: ["The movement not explained by the period's income and expenses: market-price changes on securities, foreign-currency translation, and entries made directly to equity. Derived as closing net worth less opening net worth less the net surplus."])
        valuationNote.totalLabel = "Net valuation and currency movement"
        valuationNote.totalAmounts = [valuation]

        return Statement(
            title: "Statement of Changes in Net Worth",
            entityName: entityName,
            periodLabel: currentLabel,
            unitsLabel: unitsLabel(),
            currencyCode: closing.currencyCode,
            columns: [currentLabel],
            sections: [section],
            grandTotal: nil,
            notes: [basis, valuationNote])
    }

    private func unitsLabel() -> String {
        let commodity = book.rootAccount.commodity
        let name = commodity.fullName.isEmpty ? commodity.mnemonic : commodity.fullName
        return "All amounts in \(name) (\(commodity.mnemonic))"
    }
}

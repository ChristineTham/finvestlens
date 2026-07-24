//
//  AppModel+FYPack.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The Financial Year Pack (redesign 6.6b, UC10): the EOFY bundle in one
//  export — P&L, Balance Sheet, Capital Gains, and a Dividend & Franking
//  summary — for the chosen financial year. Everything reuses the existing
//  report builders; the dividend summary is the one new document, shaped for
//  tax time: per security, franked / unfranked / imputation credits.
//

import Foundation
import FinvestLensEngine
import FinvestLensReports

@MainActor
extension AppModel {

    /// A financial year the pack can be built for, newest first: the current
    /// FY and the three before it (bounded by the book's oldest transaction).
    func packFinancialYears() -> [(label: String, from: Date, to: Date)] {
        let calendar = Calendar.current
        let oldest = book?.transactions.map(\.datePosted).min() ?? .distantFuture
        var years: [(String, Date, Date)] = []
        var range = resolve(.currentFinancialYear)
        for _ in 0..<4 {
            let endYear = calendar.component(.year, from: range.to)
            let startYear = calendar.component(.year, from: range.from)
            let label = startYear == endYear ? "FY \(endYear)" : "FY \(startYear)–\(String(endYear).suffix(2))"
            years.append((label, range.from, range.to))
            guard range.to > oldest else { break }
            let from = calendar.date(byAdding: .year, value: -1, to: range.from) ?? range.from
            let to = calendar.date(byAdding: .year, value: -1, to: range.to) ?? range.to
            range = (from, to)
        }
        return years
    }

    /// One page of the pack: an annual-report statement or a tabular report.
    enum FinancialYearPackPage {
        case statement(Statement)
        case document(ReportDocument)

        var title: String {
            switch self {
            case .statement(let statement): statement.title
            case .document(let document): document.title
            }
        }
    }

    /// The pack, in reading order: the three statements (annual-report
    /// presentation, report-redesign §3), then capital gains and the
    /// dividend & franking summary. Reports with nothing to say are skipped
    /// rather than emitted as empty pages.
    func financialYearPackPages(from: Date, to: Date, label: String) -> [FinancialYearPackPage] {
        var pages: [FinancialYearPackPage] = []
        if let income = incomeStatementStatement(from: from, to: to, periodLabel: label) {
            pages.append(.statement(income))
        }
        if let position = financialPositionStatement(asOf: to) {
            pages.append(.statement(position))
        }
        if let changes = changesInNetWorthStatement(from: from, to: to, periodLabel: label) {
            pages.append(.statement(changes))
        }
        if let cg = capitalGainsDocument(from: from, to: to) {
            pages.append(.document(cg))
        }
        if let dividends = dividendFrankingDocument(from: from, to: to, periodLabel: label) {
            pages.append(.document(dividends))
        }
        return pages
    }

    /// The pack as documents only — kept for tests that assert membership.
    func financialYearPackDocuments(from: Date, to: Date, label: String) -> [ReportDocument] {
        financialYearPackPages(from: from, to: to, label: label).compactMap {
            if case .document(let document) = $0 { return document }
            return nil
        }
    }

    /// Dividend & Franking summary: income-statement lines under a Dividends
    /// subtree, classified per security into franked / unfranked / imputation
    /// credits by account name — the same shape the book's own dividend
    /// transactions use (Dividends ▸ TICKER ▸ Franked / Unfranked /
    /// Imputation Credit). `nil` when the book records no dividend income.
    func dividendFrankingDocument(from: Date, to: Date, periodLabel: String) -> ReportDocument? {
        guard let statement = incomeStatement(from: from, to: to) else { return nil }
        let dividendLines = statement.income.filter {
            $0.fullName.localizedCaseInsensitiveContains("dividend")
        }
        guard !dividendLines.isEmpty else { return nil }

        struct SecurityDividends {
            var franked = Decimal(0)
            var unfranked = Decimal(0)
            var imputation = Decimal(0)
            var other = Decimal(0)
            var total: Decimal { franked + unfranked + imputation + other }
        }

        var bySecurity: [String: SecurityDividends] = [:]
        for line in dividendLines {
            let name = line.name.lowercased()
            // The security is the path component holding the classified leaf;
            // a flat "Dividends ▸ BHP" line is that account itself.
            let components = line.fullName.components(separatedBy: ":")
            let isLeafClass = name.contains("frank") || name.contains("imputation")
            let security = isLeafClass
                ? components.dropLast().last ?? line.name
                : line.name
            var entry = bySecurity[security] ?? SecurityDividends()
            if name.contains("unfranked") { entry.unfranked += line.amount }
            else if name.contains("frank") { entry.franked += line.amount }
            else if name.contains("imputation") { entry.imputation += line.amount }
            else { entry.other += line.amount }
            bySecurity[security] = entry
        }

        let ordered = bySecurity.sorted { $0.key < $1.key }
        let franked = ordered.reduce(Decimal(0)) { $0 + $1.value.franked }
        let unfranked = ordered.reduce(Decimal(0)) { $0 + $1.value.unfranked + $1.value.other }
        let imputation = ordered.reduce(Decimal(0)) { $0 + $1.value.imputation }

        func rows(_ keyPath: KeyPath<SecurityDividends, Decimal>) -> [ReportDocumentRow] {
            ordered.compactMap { name, entry in
                let amount = entry[keyPath: keyPath]
                return amount == 0 ? nil : ReportDocumentRow(label: name, amount: amount)
            }
        }

        return ReportDocument(
            title: "Dividends & Franking",
            periodLabel: periodLabel,
            currencyCode: statement.currencyCode,
            kpis: [
                ReportKPI(label: "Franked", amount: franked),
                ReportKPI(label: "Unfranked", amount: unfranked),
                ReportKPI(label: "Franking credits", amount: imputation),
            ],
            chart: nil,
            sections: [
                ReportDocumentSection(title: "Franked dividends", rows: rows(\.franked),
                                      total: ("Total franked", franked)),
                ReportDocumentSection(
                    title: "Unfranked dividends",
                    rows: rows(\.unfranked) + rows(\.other),
                    total: ("Total unfranked", unfranked)),
                ReportDocumentSection(title: "Franking (imputation) credits",
                                      rows: rows(\.imputation),
                                      total: ("Total credits", imputation)),
                ReportDocumentSection(
                    title: "Grossed-up total",
                    rows: [],
                    total: ("Dividends plus credits", franked + unfranked + imputation)),
            ].filter { !$0.rows.isEmpty || $0.total != nil },
            notes: ["Classified by account name under the Dividends income tree "
                    + "(Franked / Unfranked / Imputation Credit), the same shape "
                    + "the app books dividend statements into."],
            facts: nil)
    }
}

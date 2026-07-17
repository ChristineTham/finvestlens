//
//  ReportConfiguration.swift
//  FinvestLens — FeatureUI
//
//  What a report *is*, as a value: kind, period, scope. FR-RPT-04 promises
//  "save report configurations", and a configuration you can save has to be a
//  value first — the period a named rule (so "current FY" saved today still
//  means the current FY next year), the scope a set of accounts, the whole
//  thing Codable into the book's KVP like the other collections.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensReports

/// One report, fully specified.
public struct ReportConfiguration: Codable, Hashable, Sendable {
    /// The report kind's raw value. A string rather than the view-layer enum,
    /// so a saved favourite from a newer version degrades to "unknown report"
    /// instead of failing to decode the whole list.
    public var kind: String
    public var period: ReportPeriod
    /// The account scope, for the reports that take one (cash flow,
    /// transactions, reconciliation, average balance).
    public var accountIDs: Set<GncGUID>?
    /// Tree depth, for the account summary.
    public var depth: Int?
    /// The interval size, for the average-balance report.
    public var step: AverageBalanceStep?
    /// How many prior periods to show alongside the selected one as columns,
    /// for the comparative statements (0 or nil = a single period).
    public var comparePeriods: Int?

    public init(kind: String, period: ReportPeriod,
                accountIDs: Set<GncGUID>? = nil, depth: Int? = nil,
                step: AverageBalanceStep? = nil, comparePeriods: Int? = nil) {
        self.kind = kind
        self.period = period
        self.accountIDs = accountIDs
        self.depth = depth
        self.step = step
        self.comparePeriods = comparePeriods
    }
}

/// A named configuration — a favourite.
public struct SavedReport: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var configuration: ReportConfiguration

    public init(id: UUID = UUID(), name: String, configuration: ReportConfiguration) {
        self.id = id
        self.name = name
        self.configuration = configuration
    }
}

/// Book-scoped report preferences. Both optional: an absent value means the
/// default, and no slot is written until the user changes something.
public struct ReportSettings: Codable, Hashable, Sendable {
    /// 1–12; nil means "the book's convention", derived from its currency.
    public var financialYearStartMonth: Int?
    /// The period a freshly opened report starts on.
    public var defaultPeriod: ReportPeriod?

    public init(financialYearStartMonth: Int? = nil, defaultPeriod: ReportPeriod? = nil) {
        self.financialYearStartMonth = financialYearStartMonth
        self.defaultPeriod = defaultPeriod
    }
}

@MainActor
extension AppModel {

    /// When the book's financial year starts.
    ///
    /// The default is a heuristic on the book's own currency — an AUD book is
    /// almost certainly kept to the Australian July–June year — and it is only
    /// a *default*: the setting overrides it, and nothing is written to the
    /// book until the user changes it.
    public var financialYearStartMonth: Int {
        reportSettings.financialYearStartMonth ?? (reportCurrency == .aud ? 7 : 1)
    }

    /// The period a freshly opened report starts on (`FR-RPT-04`).
    public var defaultReportPeriod: ReportPeriod {
        reportSettings.defaultPeriod ?? .currentFinancialYear
    }

    /// A period as concrete dates, under this book's financial-year convention.
    public func resolve(_ period: ReportPeriod, today: Date = Date()) -> (from: Date, to: Date) {
        period.resolve(financialYearStartMonth: financialYearStartMonth, today: today)
    }

    /// A period's specific label ("FY 2026–27"), likewise.
    public func label(for period: ReportPeriod, today: Date = Date()) -> String {
        period.label(financialYearStartMonth: financialYearStartMonth, today: today)
    }

    public func updateReportSettings(_ settings: ReportSettings) {
        guard settings != reportSettings else { return }
        reportSettings = settings
        commitKvpCollections(named: "Change Report Settings")
    }

    // MARK: Favourites

    /// Saves a configuration under a name. Same-name saves replace, as with
    /// saved find queries: "FY dividends" twice is an update, not two entries.
    public func saveReportFavourite(_ configuration: ReportConfiguration, named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        savedReports.removeAll { $0.name == trimmed }
        savedReports.append(SavedReport(name: trimmed, configuration: configuration))
        savedReports.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        commitKvpCollections(named: "Save Report")
    }

    public func deleteReportFavourite(_ id: UUID) {
        savedReports.removeAll { $0.id == id }
        commitKvpCollections(named: "Delete Report")
    }
}

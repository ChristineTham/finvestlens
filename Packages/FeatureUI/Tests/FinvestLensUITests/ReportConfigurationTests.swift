//
//  ReportConfigurationTests.swift
//  FinvestLens — FeatureUI
//
//  Saved report configurations and book-scoped report settings (FR-RPT-04).
//  The properties worth pinning: favourites survive a close-and-reopen (they
//  live in the book, not the machine), same-name saves replace, and the
//  defaults — July FY for an AUD book, current FY as the period — apply
//  without writing anything to the book.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensReports
@testable import FinvestLensUI

@MainActor
@Suite("Report configuration")
struct ReportConfigurationTests {

    private func makeModel() throws -> (AppModel, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        return (model, url)
    }

    @Test("An AUD book defaults to a July financial year, without writing")
    func audDefaultsToJuly() throws {
        let (model, url) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        #expect(model.financialYearStartMonth == 7)
        #expect(model.defaultReportPeriod == .currentFinancialYear)
        // The default is a computation, not a stored value.
        #expect(model.book?.kvp["finvestlens/reportSettings"] == nil)
    }

    @Test("The setting overrides the heuristic")
    func settingWins() throws {
        let (model, url) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        model.updateReportSettings(ReportSettings(financialYearStartMonth: 4,
                                                  defaultPeriod: .currentMonth))
        #expect(model.financialYearStartMonth == 4)
        #expect(model.defaultReportPeriod == .currentMonth)
        #expect(model.book?.kvp["finvestlens/reportSettings"] != nil)
    }

    @Test("Settings and favourites survive closing and reopening the book")
    func persistence() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        defer { try? FileManager.default.removeItem(at: url) }

        let model = AppModel()
        try model.newDocument(at: url)
        model.updateReportSettings(ReportSettings(financialYearStartMonth: 7,
                                                  defaultPeriod: .previousFinancialYear))
        model.saveReportFavourite(
            ReportConfiguration(kind: "Income Statement", period: .previousFinancialYear),
            named: "Last FY P&L")
        try model.save()
        model.close()

        let reopened = AppModel()
        try await reopened.open(at: url)
        defer { reopened.close() }
        #expect(reopened.financialYearStartMonth == 7)
        #expect(reopened.defaultReportPeriod == .previousFinancialYear)
        let favourite = try #require(reopened.savedReports.first)
        #expect(favourite.name == "Last FY P&L")
        #expect(favourite.configuration.kind == "Income Statement")
        #expect(favourite.configuration.period == .previousFinancialYear)
    }

    @Test("Saving under an existing name replaces")
    func replaceByName() throws {
        let (model, url) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        model.saveReportFavourite(
            ReportConfiguration(kind: "Balance Sheet", period: .allTime), named: "Mine")
        model.saveReportFavourite(
            ReportConfiguration(kind: "Trial Balance", period: .currentMonth), named: "Mine")
        #expect(model.savedReports.count == 1)
        #expect(model.savedReports.first?.configuration.kind == "Trial Balance")
    }

    @Test("A blank name is not a favourite")
    func blankName() throws {
        let (model, url) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        model.saveReportFavourite(
            ReportConfiguration(kind: "Balance Sheet", period: .allTime), named: "   ")
        #expect(model.savedReports.isEmpty)
    }

    @Test("Deleting a favourite deletes that one")
    func deletion() throws {
        let (model, url) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        model.saveReportFavourite(
            ReportConfiguration(kind: "Balance Sheet", period: .allTime), named: "A")
        model.saveReportFavourite(
            ReportConfiguration(kind: "Cash Flow", period: .currentFinancialYear,
                                accountIDs: [.random()]), named: "B")
        let id = try #require(model.savedReports.first { $0.name == "A" }?.id)
        model.deleteReportFavourite(id)
        #expect(model.savedReports.map(\.name) == ["B"])
    }

    /// The model's resolver applies the book's convention — the same period
    /// name gives different dates under different FY settings.
    @Test("Resolution follows the book's financial year")
    func resolutionFollowsSetting() throws {
        let (model, url) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        var calendar = Calendar.current
        calendar.timeZone = .current
        let today = calendar.date(from: DateComponents(year: 2026, month: 7, day: 17))!

        let july = model.resolve(.currentFinancialYear, today: today)
        #expect(calendar.component(.month, from: july.from) == 7)

        model.updateReportSettings(ReportSettings(financialYearStartMonth: 1))
        let january = model.resolve(.currentFinancialYear, today: today)
        #expect(calendar.component(.month, from: january.from) == 1)
        #expect(calendar.component(.year, from: january.from) == 2026)
    }
}

//
//  LiveReportCatalogueTests.swift
//  FinvestLens — FeatureUI
//
//  The whole report catalogue against the real book: every scaffold kind must
//  produce a document (or a principled empty), under its default
//  configuration — the consistency the Jul 2026 report-polish pass promises.
//  Env-gated on FL_PERF_FILE; works on a copy.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensReports
@testable import FinvestLensUI

private let perfPath = ProcessInfo.processInfo.environment["FL_PERF_FILE"]

@MainActor
@Suite(.serialized)
struct LiveReportCatalogueTests {

    @Test("Every scaffold report kind renders a document from the real book")
    func catalogue() async throws {
        guard let perfPath else { return }
        let source = URL(fileURLWithPath: perfPath)
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("flcat-\(UUID().uuidString).finvestlens")
        try FileManager.default.copyItem(at: source, to: copy)
        defer {
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: copy.path + ".audit.log"))
        }

        let model = AppModel()
        await model.openBook(at: copy, breakStaleLock: true)
        defer { model.close() }
        try #require(model.book != nil)

        // Kinds that must carry real content on this book. Business aging can
        // legitimately be empty (all invoices settled), so it only has to
        // build without error.
        let mustHaveContent: Set<ReportKind> = [
            .accountSummary, .netWorth, .cashFlow, .incomeExpense, .averageBalance,
            .transactions, .reconcile, .spendingInsights,
            .portfolio, .investmentLots, .capitalGains,
        ]

        for kind in ReportKind.allCases where kind.usesScaffold {
            // The statement kinds render through the statement machinery, not
            // the scaffold builder — covered by StatementTests.
            if kind == .balanceSheet || kind == .incomeStatement
                || kind == .equityStatement || kind == .trialBalance { continue }

            let configuration = kind.defaultConfiguration(for: model)
            let document = model.reportDocument(for: configuration)
            if mustHaveContent.contains(kind) {
                let built = try #require(document, "\(kind.rawValue) built no document")
                #expect(!built.isEmpty, "\(kind.rawValue) produced an empty document")
                #expect(!built.periodLabel.isEmpty)
                print("📊 \(kind.rawValue): \(built.sections.count) sections, "
                      + "\(built.kpis.count) KPIs"
                      + (built.chart != nil ? ", chart" : "")
                      + (built.summary.isEmpty ? "" : ", \(built.summary.count) summary lines"))
            } else {
                print("📊 \(kind.rawValue): \(document == nil ? "no data (ok)" : "built")")
            }
        }

        // The two interactive tools' printable documents: the price history
        // must build on this book; the forecast legitimately prints nothing
        // when no scheduled activity is upcoming.
        #expect(model.priceHistoryDocument() != nil)
        print("📊 Forecast: \(model.forecastDocument() == nil ? "no upcoming activity (ok)" : "built")")
    }
}

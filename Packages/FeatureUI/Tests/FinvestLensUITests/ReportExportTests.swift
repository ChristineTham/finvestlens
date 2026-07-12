//
//  ReportExportTests.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensUI

@MainActor
@Suite("Report PDF export")
struct ReportExportTests {

    @Test("Renders a printable statement to valid PDF data")
    func pdf() {
        let statement = PrintableStatement(
            title: "Balance Sheet", subtitle: "As of today · AUD", code: "AUD",
            sections: [
                PrintableSection(heading: "Assets", rows: [
                    PrintableRow(label: "Bank", amount: 1000),
                    PrintableRow(label: "Total Assets", amount: 1000, bold: true),
                ]),
            ])
        let data = ReportExport.pdf(statement)
        let bytes = try? #require(data)
        #expect((bytes?.count ?? 0) > 500)
        // PDF files start with "%PDF".
        #expect(bytes?.prefix(4).elementsEqual("%PDF".utf8) == true)
    }
}

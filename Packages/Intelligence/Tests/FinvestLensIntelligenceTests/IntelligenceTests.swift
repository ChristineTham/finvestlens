//
//  IntelligenceTests.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensIntelligence
import FinvestLensEngine

@Suite("Model output parsing")
struct ParsingTests {

    @Test("Amounts tolerate symbols, separators, and negative styles")
    func amounts() {
        #expect(IntelligenceParsing.amount("$1,234.56") == Decimal(string: "1234.56"))
        #expect(IntelligenceParsing.amount("-45.20") == Decimal(string: "-45.20"))
        #expect(IntelligenceParsing.amount("(45.20)") == Decimal(string: "-45.20"))
        #expect(IntelligenceParsing.amount("45.20-") == Decimal(string: "-45.20"))
        #expect(IntelligenceParsing.amount("12.00 DR") == Decimal(string: "-12.00"))
        #expect(IntelligenceParsing.amount("+5,200.00") == Decimal(string: "5200.00"))
        #expect(IntelligenceParsing.amount("AUD 99") == Decimal(99))
        #expect(IntelligenceParsing.amount("") == nil)
        #expect(IntelligenceParsing.amount("n/a") == nil)
    }

    @Test("Dates prefer ISO and accept common statement formats")
    func dates() throws {
        let calendar = Calendar(identifier: .gregorian)
        var utc = calendar
        utc.timeZone = TimeZone(identifier: "UTC")!

        let iso = try #require(IntelligenceParsing.date("2026-03-14"))
        #expect(utc.component(.day, from: iso) == 14)
        #expect(utc.component(.month, from: iso) == 3)

        let au = try #require(IntelligenceParsing.date("14/03/2026"))
        #expect(au == iso)

        let long = try #require(IntelligenceParsing.date("14 March 2026"))
        #expect(long == iso)

        #expect(IntelligenceParsing.date("") == nil)
        #expect(IntelligenceParsing.date("not a date") == nil)
    }
}

@Suite("Account name matching")
struct AccountNameMatcherTests {

    let candidates = [
        CategoryCandidate(id: .random(), fullName: "Expenses:Food:Groceries"),
        CategoryCandidate(id: .random(), fullName: "Expenses:Food:Dining"),
        CategoryCandidate(id: .random(), fullName: "Expenses:Transport:Fuel"),
        CategoryCandidate(id: .random(), fullName: "Expenses:Utilities:Gas & Electricity"),
        CategoryCandidate(id: .random(), fullName: "Income:Salary"),
    ]

    @Test("Exact full name wins")
    func exactFullName() {
        let hit = AccountNameMatcher.match("Expenses:Food:Groceries", in: candidates)
        #expect(hit?.fullName == "Expenses:Food:Groceries")
    }

    @Test("Leaf name resolves to its account")
    func leafName() {
        #expect(AccountNameMatcher.match("Groceries", in: candidates)?.fullName == "Expenses:Food:Groceries")
        #expect(AccountNameMatcher.match("Salary", in: candidates)?.fullName == "Income:Salary")
    }

    @Test("Partial colon path matches as a suffix")
    func pathSuffix() {
        let hit = AccountNameMatcher.match("Food:Dining", in: candidates)
        #expect(hit?.fullName == "Expenses:Food:Dining")
    }

    @Test("Case and ampersand differences are ignored")
    func normalization() {
        let hit = AccountNameMatcher.match("gas and electricity", in: candidates)
        #expect(hit?.fullName == "Expenses:Utilities:Gas & Electricity")
    }

    @Test("Arrow-separated model answers resolve via their last component")
    func arrowSeparated() {
        let hit = AccountNameMatcher.match("Expenses > Dining", in: candidates)
        #expect(hit?.fullName == "Expenses:Food:Dining")
    }

    @Test("Unrelated names do not match")
    func noMatch() {
        #expect(AccountNameMatcher.match("Quantum Flux", in: candidates) == nil)
        #expect(AccountNameMatcher.match("", in: candidates) == nil)
    }
}

@Suite("Dividend statement details")
struct DividendDetailsTests {

    @Test("Components reconcile against the net payment")
    func componentsCheck() {
        var details = DividendStatementDetails(
            frankedAmount: 70, unfrankedAmount: 30, frankingCredits: 30, netPayment: 100
        )
        #expect(details.componentsMatchPayment)
        details.netPayment = 130  // credits wrongly included in cash
        #expect(!details.componentsMatchPayment)
    }
}

@Suite("Document classification keywords")
struct ClassifierKeywordTests {

    @Test("Dividend statements are recognised before generic statements")
    func dividend() {
        let text = "BHP GROUP LIMITED — DIVIDEND STATEMENT\nFranking credits 176.70"
        #expect(DocumentClassifier.classifyByKeywords(text) == .dividendStatement)
    }

    @Test("Bank statements are recognised by statement/balance wording")
    func statement() {
        let text = "EXAMPLE BANK — Everyday Account Statement\nOpening balance 4,120.55"
        #expect(DocumentClassifier.classifyByKeywords(text) == .bankStatement)
    }

    @Test("Invoices are recognised by invoice/receipt wording")
    func invoice() {
        #expect(DocumentClassifier.classifyByKeywords("OFFICEWORKS — TAX INVOICE #IN-1") == .invoice)
        #expect(DocumentClassifier.classifyByKeywords("Subtotal 90.00\nGST 9.00\nTotal 99.00") == .invoice)
    }

    @Test("Unrelated text is unknown")
    func unknown() {
        #expect(DocumentClassifier.classifyByKeywords("Meeting notes for Tuesday") == .unknown)
    }
}

@Suite("Budget advisor fallback")
struct BudgetFallbackTests {

    @available(macOS 26.0, iOS 26.0, *)
    @Test("Average-based fallback budgets every category at its average")
    func averageFallback() {
        let history = [
            SpendingHistory(categoryID: .random(), fullName: "Expenses:Groceries",
                            monthlyAverage: 820, monthlyMinimum: 760, monthlyMaximum: 905),
            SpendingHistory(categoryID: .random(), fullName: "Expenses:Dining",
                            monthlyAverage: 460, monthlyMinimum: 300, monthlyMaximum: 640),
        ]
        let suggestion = BudgetAdvisor.averageBasedSuggestion(history)
        #expect(suggestion.lines.count == 2)
        #expect(suggestion.lines[0].monthlyAmount == 820)
        #expect(suggestion.lines[1].monthlyAmount == 460)
        #expect(suggestion.totalBudget == 1280)
        #expect(suggestion.summary.contains("averages"))
    }
}

@Suite("Invoice analysis")
struct InvoiceAnalysisTests {

    @Test("Line item sum exposes extraction discrepancies")
    func lineItemSum() {
        let analysis = InvoiceAnalysis(
            vendor: "Test", date: nil, total: Decimal(string: "100.00")!,
            lineItems: [
                InvoiceLineItem(itemDescription: "A", amount: Decimal(string: "60.00")!),
                InvoiceLineItem(itemDescription: "B", amount: Decimal(string: "39.00")!),
            ]
        )
        #expect(analysis.lineItemSum == Decimal(string: "99.00"))
        #expect(analysis.lineItemSum != analysis.total)
    }
}

#if os(macOS)
import CoreGraphics
import CoreText

@Suite("Document text extraction")
struct DocumentTextTests {

    /// Renders a one-page text PDF, round-trips it through DocumentText.
    @Test("Text-based PDF pages extract directly")
    func textPDF() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("finvestlens-test-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        let text = "STATEMENT 14/03/2026 WOOLWORTHS -45.20"
        let attributed = NSAttributedString(string: text, attributes: [
            .font: CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()

        let pages = try await DocumentText.extractPages(from: url)
        #expect(pages.count == 1)
        #expect(pages.first?.text.contains("WOOLWORTHS") == true)

        let whole = try await DocumentText.extractText(from: url)
        #expect(whole.contains("-45.20"))
    }

    @Test("Unreadable files throw emptyDocument")
    func unreadable() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("finvestlens-test-missing-\(UUID().uuidString).pdf")
        await #expect(throws: (any Error).self) {
            _ = try await DocumentText.extractPages(from: url)
        }
    }
}
#endif

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

    @Test("Debit/credit markers and bracketed symbols keep their sign")
    func debitCreditMarkers() {
        #expect(IntelligenceParsing.amount("DR 45.20") == Decimal(string: "-45.20"))
        #expect(IntelligenceParsing.amount("CR 12.00") == Decimal(string: "12.00"))
        #expect(IntelligenceParsing.amount("($1,045.99)") == Decimal(string: "-1045.99"))
        #expect(IntelligenceParsing.amount("   ") == nil)
        #expect(IntelligenceParsing.amount("DR") == nil)
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

    @Test("Slashed ISO and US-style month names parse to the same day")
    func alternateDateForms() throws {
        let iso = try #require(IntelligenceParsing.date("2026-03-14"))
        #expect(IntelligenceParsing.date("2026/03/14") == iso)
        #expect(IntelligenceParsing.date("March 14, 2026") == iso)
        #expect(IntelligenceParsing.date("  2026-03-14  ") == iso)
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
import ImageIO

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

    /// Draws pages of `(text, x, y)` runs into a PDF and returns its bytes.
    private func renderPDF(pages: [[(String, CGFloat, CGFloat)]]) throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        for runs in pages {
            context.beginPDFPage(nil)
            for (text, x, y) in runs {
                let attributed = NSAttributedString(string: text, attributes: [.font: font])
                context.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// The content stream carries the amounts first and the bottom row before
    /// the top row — `PDFPage.string` detaches the amounts from their payees.
    /// The geometric reflow must reunite each row (top-first, left-to-right)
    /// and keep the column break visible as a wide gap.
    @Test("Two-column statement rows reflow into visual order")
    func columnReflow() async throws {
        let data = try renderPDF(pages: [[
            ("-45.20", 420, 650),
            ("WOOLWORTHS METRO", 72, 650),
            ("-12.00", 420, 700),
            ("COFFEE 11 RUN", 72, 700),
        ]])
        let pages = try await DocumentText.extractPages(from: data)
        #expect(pages.count == 1)
        let lines = (pages.first?.text ?? "").components(separatedBy: "\n")
        #expect(lines == ["COFFEE 11 RUN   -12.00", "WOOLWORTHS METRO   -45.20"])
    }

    @Test("Word spacing and separators inside one run survive the reflow")
    func pdfData() async throws {
        let data = try renderPDF(pages: [[("Opening balance 4,120.55", 72, 700)]])
        let text = try await DocumentText.extractText(from: data)
        #expect(text == "Opening balance 4,120.55")
    }

    @Test("Pages keep their 1-based numbers and join with blank lines")
    func multiPage() async throws {
        let data = try renderPDF(pages: [
            [("PAGE ONE 1.00", 72, 700)],
            [("PAGE TWO 2.00", 72, 700)],
        ])
        let pages = try await DocumentText.extractPages(from: data)
        #expect(pages.map(\.number) == [1, 2])
        #expect(pages.map(\.text) == ["PAGE ONE 1.00", "PAGE TWO 2.00"])
        let joined = try await DocumentText.extractText(from: data)
        #expect(joined == "PAGE ONE 1.00\n\nPAGE TWO 2.00")
    }

    @Test("An all-blank PDF page falls back to OCR, then emptyDocument")
    func blankPage() async throws {
        let data = try renderPDF(pages: [[]])
        await #expect(throws: IntelligenceError.self) {
            _ = try await DocumentText.extractPages(from: data)
        }
    }

    @Test("Non-document bytes throw emptyDocument")
    func garbageData() async throws {
        await #expect(throws: IntelligenceError.self) {
            _ = try await DocumentText.extractPages(from: Data("just some plain text".utf8))
        }
    }

    @Test("A blank raster image yields emptyDocument, after an upscaled retry")
    func blankImage() async throws {
        // A 300×150 all-white PNG: decodes as an image, contains no text, so
        // recognition (original, then 2× upscale) finds nothing.
        let context = try #require(CGContext(
            data: nil, width: 300, height: 150,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 150))
        let image = try #require(context.makeImage())
        let png = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(png as CFMutableData, "public.png" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        await #expect(throws: IntelligenceError.self) {
            _ = try await DocumentText.extractPages(from: png as Data)
        }
    }
}
#endif

@Suite("Amount parsing — debit-marker tokens")
struct DebitMarkerTests {
    @Test("DR flips sign only as its own token, never inside a currency code")
    func drIsAToken() {
        #expect(IntelligenceParsing.amount("500 DR") == -500)
        #expect(IntelligenceParsing.amount("DR 500") == -500)
        // "IDR" is Indonesian rupiah, not a debit marker.
        #expect(IntelligenceParsing.amount("500 IDR") == 500)
        #expect(IntelligenceParsing.amount("1,000 SDR") == 1000)
    }
}

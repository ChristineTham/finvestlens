//
//  DocumentText.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(Vision)
import Vision
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Extracts plain text from financial documents (PDF statements, invoices).
///
/// Text-based PDFs read directly through PDFKit; pages with no text layer
/// (scans) fall back to Vision OCR on a rendered bitmap. Results are returned
/// per page so callers can chunk model requests — the on-device model has a
/// small context window, and statements are naturally page-structured.
public enum DocumentText {

    /// One page of extracted text, 1-based page numbers.
    public struct Page: Sendable {
        public let number: Int
        public let text: String
    }

    public static func extractPages(from url: URL) async throws -> [Page] {
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: url) else {
            throw IntelligenceError.emptyDocument
        }
        return try await extractPages(from: document)
        #else
        throw IntelligenceError.unavailable("PDF reading is not supported on this platform.")
        #endif
    }

    public static func extractPages(from data: Data) async throws -> [Page] {
        #if canImport(PDFKit)
        guard let document = PDFDocument(data: data) else {
            throw IntelligenceError.emptyDocument
        }
        return try await extractPages(from: document)
        #else
        throw IntelligenceError.unavailable("PDF reading is not supported on this platform.")
        #endif
    }

    #if canImport(PDFKit)
    private static func extractPages(from document: PDFDocument) async throws -> [Page] {
        var pages: [Page] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var text = layoutText(for: page)
                ?? page.string?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? ""
            if text.count < 32 {  // likely a scanned page — try OCR
                #if canImport(Vision)
                if let recognized = try? await ocr(page: page), recognized.count > text.count {
                    text = recognized
                }
                #endif
            }
            if !text.isEmpty {
                pages.append(Page(number: index + 1, text: text))
            }
        }
        guard !pages.isEmpty else { throw IntelligenceError.emptyDocument }
        return pages
    }

    /// Rebuilds a page's text in visual order from per-character bounds.
    ///
    /// `PDFPage.string` returns characters in content-stream order, which for
    /// column-aligned documents (statements, invoices) interleaves and reorders
    /// rows — an amount can detach from its line entirely. Reflowing by
    /// geometry (group glyphs into rows by baseline, sort each row
    /// left-to-right, respace from the x-gaps) restores the table structure
    /// the model needs.
    private static func layoutText(for page: PDFPage) -> String? {
        guard let raw = page.string as NSString?, raw.length > 0 else { return nil }

        struct PlacedChar {
            let character: String
            let x: CGFloat
            let width: CGFloat
            let baseline: CGFloat
        }
        var placed: [PlacedChar] = []
        placed.reserveCapacity(raw.length)
        // characterBounds(at:) indexes the glyph stream, which does not
        // include the newlines PDFKit synthesizes into `string` — offset by
        // the newlines seen so far or every line after the first shifts.
        var newlines = 0
        for index in 0..<raw.length {
            let character = raw.substring(with: NSRange(location: index, length: 1))
            if character == "\n" || character == "\r" {
                newlines += 1
                continue
            }
            let bounds = page.characterBounds(at: index - newlines)
            // Whitespace is reconstructed from gaps below (space glyphs often
            // have empty bounds anyway).
            guard !bounds.isEmpty, !bounds.isInfinite,
                  !character.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            placed.append(PlacedChar(character: character, x: bounds.minX,
                                     width: bounds.width, baseline: bounds.minY))
        }
        guard !placed.isEmpty else { return nil }

        // Group into rows by baseline (PDF space: top of page first). The
        // tolerance absorbs descenders and short glyphs like the period.
        let sorted = placed.sorted { $0.baseline > $1.baseline }
        let tolerance: CGFloat = 5
        var rows: [[PlacedChar]] = []
        var currentRow: [PlacedChar] = []
        var currentY = sorted[0].baseline
        for item in sorted {
            if abs(item.baseline - currentY) <= tolerance {
                currentRow.append(item)
            } else {
                rows.append(currentRow)
                currentRow = [item]
                currentY = item.baseline
            }
        }
        rows.append(currentRow)

        let lines: [String] = rows.map { row in
            let ordered = row.sorted { $0.x < $1.x }
            var line = ""
            var previousEnd: CGFloat?
            for item in ordered {
                if let end = previousEnd {
                    let gap = item.x - end
                    if gap > 12 {
                        line += "   "  // wide gap: keep the column break visible
                    } else if gap > 1.2 {
                        line += " "
                    }
                }
                line += item.character
                previousEnd = item.x + item.width
            }
            return line.trimmingCharacters(in: .whitespaces)
        }
        let text = lines.filter { !$0.isEmpty }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
    #endif

    /// Convenience: the whole document as one string (small documents such as
    /// invoices and dividend statements).
    public static func extractText(from url: URL) async throws -> String {
        try await extractPages(from: url).map(\.text).joined(separator: "\n\n")
    }

    public static func extractText(from data: Data) async throws -> String {
        try await extractPages(from: data).map(\.text).joined(separator: "\n\n")
    }

    #if canImport(PDFKit) && canImport(Vision)
    private static func ocr(page: PDFPage) async throws -> String? {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.5  // ~180 dpi, enough for statement type sizes
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { return nil }

        // Prefer the structured document reader (Vision 26): it groups a
        // statement grid into tables, so rows/columns survive as tab-separated
        // text instead of collapsing into loose lines. Fall back to plain text
        // recognition when it finds no structure.
        if let structured = try? await recognizeDocument(image), !structured.isEmpty {
            return structured
        }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let observations = try await request.perform(on: image)
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Reads a rendered page as a structured document, reconstructing detected
    /// tables as tab-separated rows so the model sees the statement grid rather
    /// than a reflowed wall of text.
    private static func recognizeDocument(_ image: CGImage) async throws -> String? {
        let observations = try await RecognizeDocumentsRequest().perform(on: image)
        guard let document = observations.first?.document else { return nil }
        var blocks: [String] = []
        for table in document.tables {
            for row in table.rows {
                let cells = row.map { $0.content.text.transcript }
                let line = cells.joined(separator: "\t").trimmingCharacters(in: .whitespaces)
                if !line.isEmpty { blocks.append(line) }
            }
        }
        let body = document.text.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if blocks.isEmpty { return body.isEmpty ? nil : body }
        if !body.isEmpty { blocks.append(body) }
        return blocks.joined(separator: "\n")
    }
    #endif
}

//
//  GzipDateTests.swift
//  FinvestLens — Interchange
//
//  The gzip container reader (compressed GnuCash files) and the GnuCash date
//  codec — small, foundational, and previously under-tested.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Compression
import Testing
@testable import FinvestLensInterchange

@Suite("Gzip container — headers & errors")
struct GzipContainerTests {

    /// Builds a real gzip file for `payload` with the system's own deflate.
    private func gzip(_ payload: Data, flags: UInt8 = 0,
                      name: String? = nil) -> Data {
        var deflated = Data(count: payload.count + 512)
        let written = deflated.withUnsafeMutableBytes { out in
            payload.withUnsafeBytes { input in
                compression_encode_buffer(
                    out.bindMemory(to: UInt8.self).baseAddress!, out.count,
                    input.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        deflated = deflated.prefix(written)

        var out = Data([0x1f, 0x8b, 0x08, name == nil ? flags : (flags | 0x08),
                        0, 0, 0, 0, 0, 0x03])
        if let name {
            out.append(contentsOf: Array(name.utf8))
            out.append(0)
        }
        out.append(deflated)
        var crc = UInt32(crc32Value(payload)).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        var size = UInt32(payload.count % (1 << 32)).littleEndian
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
    }

    private func crc32Value(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }

    @Test("Detects the gzip magic and inflates a real container")
    func roundTrip() throws {
        let payload = Data(String(repeating: "<gnc-v2>hello gnucash</gnc-v2>\n", count: 50).utf8)
        let packed = gzip(payload)
        #expect(Gzip.isGzipped(packed))
        #expect(!Gzip.isGzipped(payload))
        #expect(try Gzip.decompress(packed) == payload)
        // decompressIfNeeded passes plain data through untouched.
        #expect(try Gzip.decompressIfNeeded(payload) == payload)
        #expect(try Gzip.decompressIfNeeded(packed) == payload)
    }

    @Test("A FNAME header (as gzip CLI writes) is skipped correctly")
    func namedMember() throws {
        let payload = Data("named payload".utf8)
        let packed = gzip(payload, name: "book.gnucash")
        #expect(try Gzip.decompress(packed) == payload)
    }

    @Test("Not-gzip and truncated inputs throw their own errors")
    func errors() {
        #expect(throws: Gzip.GzipError.notGzip) {
            try Gzip.decompress(Data("plain".utf8))
        }
        #expect(throws: Gzip.GzipError.truncated) {
            try Gzip.decompress(Data([0x1f, 0x8b, 0x08, 0x00]))
        }
    }
}

@Suite("GnuCash date codec — forms & round-trip")
struct GnuCashDateCodecTests {

    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0,
                     _ s: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min; c.second = s
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    @Test("Parses ts:date forms with and without colons in the offset")
    func timestampForms() {
        #expect(GnuCashDate.parse("2026-06-01 10:59:00 +0000") == utc(2026, 6, 1, 10, 59))
        #expect(GnuCashDate.parse("2026-06-01 10:59:00 +00:00") == utc(2026, 6, 1, 10, 59))
        #expect(GnuCashDate.parse(" 2026-06-01 10:59:00 +0000 ") == utc(2026, 6, 1, 10, 59))
        // A non-UTC offset lands on the corresponding UTC instant.
        #expect(GnuCashDate.parse("2026-06-01 20:00:00 +1000") == utc(2026, 6, 1, 10, 0))
    }

    @Test("Parses gdate day-only form; garbage returns nil")
    func gdateForm() {
        #expect(GnuCashDate.parse("2026-06-01") == utc(2026, 6, 1))
        #expect(GnuCashDate.parse("not a date") == nil)
        #expect(GnuCashDate.parse("") == nil)
    }

    @Test("Format and day-only round-trip through parse")
    func formatting() {
        let stamp = utc(2026, 6, 1, 10, 59)
        #expect(GnuCashDate.parse(GnuCashDate.format(stamp)) == stamp)
        let day = utc(2026, 6, 1)
        #expect(GnuCashDate.formatDayOnly(day) == "2026-06-01")
        #expect(GnuCashDate.isDayOnly(day))
        #expect(!GnuCashDate.isDayOnly(stamp))
        // One second past midnight is no longer day-only.
        #expect(!GnuCashDate.isDayOnly(day.addingTimeInterval(1)))
    }
}

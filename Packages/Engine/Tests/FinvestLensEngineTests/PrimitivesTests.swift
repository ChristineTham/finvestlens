//
//  PrimitivesTests.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

@Suite("GncGUID")
struct GncGUIDTests {

    @Test("Canonical hex is 32 lowercase chars with no dashes")
    func canonicalForm() throws {
        let guid = GncGUID.random()
        #expect(guid.hexString.count == 32)
        #expect(!guid.hexString.contains("-"))
        #expect(guid.hexString == guid.hexString.lowercased())
    }

    @Test("Hex round-trips byte-for-byte")
    func hexRoundTrip() throws {
        let original = "0123456789abcdef0123456789abcdef"
        let guid = try #require(GncGUID(hex: original))
        #expect(guid.hexString == original)
        #expect(guid.bytes.count == 16)
    }

    @Test("Dashed input is tolerated, output is canonical")
    func dashedInput() throws {
        let guid = try #require(GncGUID(hex: "01234567-89ab-cdef-0123-456789abcdef"))
        #expect(guid.hexString == "0123456789abcdef0123456789abcdef")
    }

    @Test("Invalid hex is rejected")
    func invalidHex() {
        #expect(GncGUID(hex: "tooshort") == nil)
        #expect(GncGUID(hex: String(repeating: "z", count: 32)) == nil)
    }

    @Test("Codable encodes as the hex string")
    func codable() throws {
        let guid = GncGUID.random()
        let data = try JSONEncoder().encode(guid)
        #expect(String(data: data, encoding: .utf8) == "\"\(guid.hexString)\"")
        let decoded = try JSONDecoder().decode(GncGUID.self, from: data)
        #expect(decoded == guid)
    }

    @Test("Random GUIDs are distinct")
    func randomness() {
        let guids = (0..<1000).map { _ in GncGUID.random() }
        #expect(Set(guids).count == 1000)
    }
}

@Suite("KvpFrame")
struct KvpTests {

    @Test("Nested frame round-trips through Codable")
    func codableRoundTrip() throws {
        var inner = KvpFrame()
        inner["reconcile-date"] = .date(Date(timeIntervalSince1970: 1_000_000))
        inner["amount"] = .numeric(Decimal(string: "12.34")!)

        var frame = KvpFrame()
        frame["notes"] = .string("hello")
        frame["count"] = .int64(42)
        frame["ratio"] = .double(0.5)
        frame["ref"] = .guid(GncGUID.random())
        frame["nested"] = .frame(inner)
        frame["tags"] = .list([.string("a"), .string("b")])

        let data = try JSONEncoder().encode(frame)
        let decoded = try JSONDecoder().decode(KvpFrame.self, from: data)
        #expect(decoded == frame)
    }

    @Test("Subscript access")
    func subscriptAccess() {
        var frame = KvpFrame()
        frame["k"] = .string("v")
        #expect(frame["k"] == .string("v"))
        #expect(frame["missing"] == nil)
        #expect(!frame.isEmpty)
    }
}

@Suite("Commodity")
struct CommodityTests {

    @Test("Currency helper sets fraction and digits")
    func currencyHelper() {
        #expect(Commodity.aud.smallestFraction == 100)
        #expect(Commodity.aud.fractionDigits == 2)

        let jpy = Commodity.currency("JPY", fractionDigits: 0)
        #expect(jpy.smallestFraction == 1)
        #expect(jpy.fractionDigits == 0)
    }

    @Test("Rounding respects the fraction")
    func rounding() {
        #expect(Commodity.aud.round(Decimal(string: "1.239")!) == Decimal(string: "1.24")!)
        let mills = Commodity.currency("XXX", fractionDigits: 3)
        #expect(mills.round(Decimal(string: "1.2345")!) == Decimal(string: "1.234")!
             || mills.round(Decimal(string: "1.2345")!) == Decimal(string: "1.235")!)
    }

    @Test("Identity by namespace and mnemonic")
    func identity() {
        #expect(Commodity.currency("AUD") == Commodity.aud)
        #expect(Commodity.aud != Commodity.usd)
        // Quote config and slots are descriptive, not identity.
        var configured = Commodity.aud
        configured.getQuotes = true
        configured.kvp["user_symbol"] = .string("$")
        #expect(configured == Commodity.aud)
    }

    @Test("JSON from before the quote fields still decodes")
    func legacyDecode() throws {
        // Encoded by the pre-quote-fields Commodity (no exchangeCode /
        // getQuotes / quoteSource / quoteTimezone / kvp keys).
        let legacy = """
        {"namespace":{"currency":{}},"mnemonic":"AUD","fullName":"Australian Dollar",
         "smallestFraction":100,"roundingMode":"plain"}
        """
        let decoded = try JSONDecoder().decode(Commodity.self, from: Data(legacy.utf8))
        #expect(decoded == .aud)
        #expect(decoded.fullName == "Australian Dollar")
        #expect(!decoded.getQuotes && decoded.exchangeCode == nil && decoded.kvp.isEmpty)
    }

    @Test("Quote fields survive a Codable round-trip")
    func quoteFieldsCodable() throws {
        var stock = Commodity(namespace: .security("ASX"), mnemonic: "BHP",
                              fullName: "BHP Group", smallestFraction: 10000)
        stock.exchangeCode = "BHP.AX"
        stock.getQuotes = true
        stock.quoteSource = "yahoo_json"
        stock.quoteTimezone = ""
        stock.kvp["user_symbol"] = .string("BHP")
        let decoded = try JSONDecoder().decode(
            Commodity.self, from: JSONEncoder().encode(stock))
        #expect(decoded.exchangeCode == "BHP.AX")
        #expect(decoded.getQuotes)
        #expect(decoded.quoteSource == "yahoo_json")
        #expect(decoded.quoteTimezone == "")
        #expect(decoded.kvp["user_symbol"] == .string("BHP"))
    }
}

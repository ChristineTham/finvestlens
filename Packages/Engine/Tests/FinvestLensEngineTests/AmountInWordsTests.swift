//
//  AmountInWordsTests.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

@Suite("Amount in words")
struct AmountInWordsTests {

    @Test("The legal line spells whole dollars and a cents fraction")
    func basic() {
        #expect(AmountInWords.english(dec("1234.50")) == "One thousand two hundred thirty-four and 50/100")
        #expect(AmountInWords.english(dec("0.99")) == "Zero and 99/100")
        #expect(AmountInWords.english(dec("100")) == "One hundred and 00/100")
        #expect(AmountInWords.english(dec("1000000")) == "One million and 00/100")
    }

    @Test("Teens, tens and hyphenation follow US-check convention")
    func hyphenation() {
        #expect(AmountInWords.words(forWholeNumber: 15) == "fifteen")
        #expect(AmountInWords.words(forWholeNumber: 42) == "forty-two")
        #expect(AmountInWords.words(forWholeNumber: 105) == "one hundred five")
        #expect(AmountInWords.words(forWholeNumber: 2001) == "two thousand one")
    }

    @Test("Cents round to the minor unit and a negative amount uses its magnitude")
    func roundingAndSign() {
        // 5.005 rounds to 5.01 → "01/100".
        #expect(AmountInWords.english(dec("5.005")) == "Five and 01/100")
        // A check is never for a negative sum; the magnitude is spelled.
        #expect(AmountInWords.english(dec("-40.25")) == "Forty and 25/100")
    }
}

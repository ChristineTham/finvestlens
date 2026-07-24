//
//  MoneyTests.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

@Suite("Money")
struct MoneyTests {

    @Test("Rounds to the commodity fraction (half away from zero)")
    func rounding() {
        #expect(Money(dec("10.005"), .aud).rounded.amount == dec("10.01"))
        #expect(Money(dec("10.004"), .aud).rounded.amount == dec("10.00"))
        #expect(Money(dec("-10.005"), .aud).rounded.amount == dec("-10.01"))
    }

    @Test("isZero tolerates residuals below one minor unit")
    func zeroTolerance() {
        #expect(Money(dec("0.004"), .aud).isZero)
        #expect(!Money(dec("0.006"), .aud).isZero)
        #expect(Money.zero(.aud).isZero)
    }

    @Test("Same-commodity arithmetic")
    func arithmetic() {
        let a = Money(dec("100.00"), .aud)
        let b = Money(dec("25.50"), .aud)
        #expect((a + b).amount == dec("125.50"))
        #expect((a - b).amount == dec("74.50"))
        #expect((-b).amount == dec("-25.50"))
        #expect((a * dec("2")).amount == dec("200.00"))
    }

    @Test("adding returns nil across commodities")
    func mixedCommodityAdding() {
        #expect(Money(dec("1"), .aud).adding(Money(dec("1"), .usd)) == nil)
        #expect(Money(dec("1"), .aud).adding(Money(dec("2"), .aud))?.amount == dec("3"))
    }

    @Test("Comparison and sign")
    func comparison() {
        #expect(Money(dec("1.00"), .aud) < Money(dec("2.00"), .aud))
        #expect(Money(dec("-1.00"), .aud).isNegative)
        #expect(Money(dec("1.00"), .aud).isPositive)
    }

    @Test("Value equality ignores decimal scale")
    func equality() {
        #expect(Money(dec("1.0"), .aud) == Money(dec("1.00"), .aud))
    }
}

@Suite("Money gaps")
struct MoneyGapTests {

    @Test("Compound assignment operators")
    func compoundAssignment() {
        var total = Money(dec("10.00"), .aud)
        total += Money(dec("2.50"), .aud)
        #expect(total.amount == dec("12.50"))
        total -= Money(dec("0.50"), .aud)
        #expect(total.amount == dec("12.00"))
        #expect(total.commodity == .aud)
    }

    @Test("Sub-minor residuals are neither positive nor negative")
    func residualSign() {
        #expect(!Money(dec("0.004"), .aud).isPositive)
        #expect(!Money(dec("-0.004"), .aud).isNegative)
        #expect(Money(dec("0.006"), .aud).isPositive)
        #expect(Money(dec("-0.006"), .aud).isNegative)
        #expect(!Money.zero(.aud).isPositive && !Money.zero(.aud).isNegative)
    }

    @Test("Scaling by a decimal factor keeps the raw product un-rounded")
    func scaling() {
        let price = Money(dec("10.00"), .aud) * dec("0.333")
        #expect(price.amount == dec("3.33"))
        let residual = Money(dec("0.05"), .aud) * dec("0.1")
        #expect(residual.amount == dec("0.005"))          // not auto-rounded
        #expect(residual.rounded.amount == dec("0.01"))   // rounds on demand
    }

    @Test("Rounding honours the commodity's mode, sign-relative")
    func roundingModes() {
        let down = Commodity.currency("AUD", roundingMode: .down)     // toward zero
        #expect(Money(dec("10.019"), down).rounded.amount == dec("10.01"))
        #expect(Money(dec("-10.019"), down).rounded.amount == dec("-10.01"))

        let up = Commodity.currency("AUD", roundingMode: .up)         // away from zero
        #expect(Money(dec("10.011"), up).rounded.amount == dec("10.02"))
        #expect(Money(dec("-10.011"), up).rounded.amount == dec("-10.02"))
        #expect(Money(dec("10.01"), up).rounded.amount == dec("10.01"))  // exact stays put

        let bankers = Commodity.currency("AUD", roundingMode: .bankers)
        #expect(Money(dec("10.005"), bankers).rounded.amount == dec("10.00"))  // half to even
        #expect(Money(dec("10.015"), bankers).rounded.amount == dec("10.02"))
        #expect(Money(dec("-10.005"), bankers).rounded.amount == dec("-10.00"))
    }

    @Test("Formatted output rounds to the commodity fraction")
    func formatted() {
        let en = Locale(identifier: "en_US")
        #expect(Money(dec("1234.565"), .usd).formatted(locale: en) == "$1,234.57")
        #expect(Money(dec("1234.565"), .aud).formatted(locale: en).contains("1,234.57"))
        #expect(Money(dec("-2.5"), .usd).formatted(locale: en).contains("2.50"))

        // Zero-decimal currency: rounds to whole units, no fraction shown.
        let jpy = Commodity.currency("JPY", fractionDigits: 0)
        let yen = Money(dec("1234.56"), jpy).formatted(locale: en)
        #expect(yen.contains("1,235"))
        #expect(!yen.contains("."))

        // Non-decimal fraction (quarters): no fixed precision is forced.
        let quarters = Commodity(namespace: .currency, mnemonic: "XTS",
                                 fullName: "Test", smallestFraction: 4)
        #expect(quarters.fractionDigits == nil)
        #expect(Money(dec("10.126"), quarters).formatted(locale: en).contains("10.25"))
    }
}

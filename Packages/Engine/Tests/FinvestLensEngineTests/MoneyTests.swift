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

//
//  AmountExpressionTests.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

@Suite("Amount expression")
struct AmountExpressionTests {

    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    @Test("A plain number returns itself")
    func plain() {
        #expect(AmountExpression.evaluate("42") == dec("42"))
        #expect(AmountExpression.evaluate("10.50") == dec("10.50"))
        #expect(AmountExpression.evaluate("  3.14 ") == dec("3.14"))
    }

    @Test("Arithmetic with precedence and parentheses")
    func arithmetic() {
        #expect(AmountExpression.evaluate("5*3") == dec("15"))
        #expect(AmountExpression.evaluate("10.50 + 2") == dec("12.50"))
        #expect(AmountExpression.evaluate("2 + 3 * 4") == dec("14"))       // precedence
        #expect(AmountExpression.evaluate("(1 + 2) / 3") == dec("1"))
        #expect(AmountExpression.evaluate("100 - 20 - 5") == dec("75"))    // left-assoc
    }

    @Test("Unary sign")
    func unary() {
        #expect(AmountExpression.evaluate("-5") == dec("-5"))
        #expect(AmountExpression.evaluate("3 * -2") == dec("-6"))
        #expect(AmountExpression.evaluate("-(2 + 3)") == dec("-5"))
    }

    @Test("Comma grouping in the integer part is ignored")
    func grouping() {
        #expect(AmountExpression.evaluate("1,000") == dec("1000"))
        #expect(AmountExpression.evaluate("1,234.56") == dec("1234.56"))
    }

    @Test("Invalid expressions and division by zero return nil")
    func invalid() {
        #expect(AmountExpression.evaluate("") == nil)
        #expect(AmountExpression.evaluate("5 +") == nil)
        #expect(AmountExpression.evaluate("(1 + 2") == nil)
        #expect(AmountExpression.evaluate("1 2") == nil)
        #expect(AmountExpression.evaluate("abc") == nil)   // unbound variable
        #expect(AmountExpression.evaluate("5 / 0") == nil)
    }

    @Test("Variables resolve from the binding (FR-SCH-02)")
    func variables() {
        let vars = ["principal": dec("800"), "interest": dec("200")]
        #expect(AmountExpression.evaluate("principal + interest", variables: vars) == dec("1000"))
        #expect(AmountExpression.evaluate("principal * 1.1", variables: ["principal": dec("100")]) == dec("110"))
        // An unbound variable still fails.
        #expect(AmountExpression.evaluate("principal + interest", variables: ["principal": dec("800")]) == nil)
    }

    @Test("variables(in:) collects the identifiers a formula needs")
    func collectVariables() {
        #expect(AmountExpression.variables(in: "principal + interest") == ["principal", "interest"])
        #expect(AmountExpression.variables(in: "rate * balance / 12") == ["rate", "balance"])
        #expect(AmountExpression.variables(in: "10.50 + 2").isEmpty)
    }
}

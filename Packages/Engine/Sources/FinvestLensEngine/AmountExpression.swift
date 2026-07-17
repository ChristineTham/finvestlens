//
//  AmountExpression.swift
//  FinvestLens — Engine
//
//  Arithmetic in amount fields, ported from GnuCash's `gnc-exp-parser`
//  (`FR-SCH-02`). GnuCash lets you type `5*3`, `10.50 + 2`, or `(1+2)/3` into an
//  amount cell and evaluates it. This is a small recursive-descent evaluator
//  over `Decimal` covering the arithmetic the amount fields actually use:
//  `+ - * /`, parentheses, and unary sign, left-associative with the usual
//  precedence.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Evaluates an arithmetic expression typed into an amount field.
public enum AmountExpression {

    /// Evaluates `input` to a `Decimal`, or `nil` if it is not a valid
    /// expression (or divides by zero). A plain number returns itself, so this
    /// is safe to run on every amount entry.
    ///
    /// The decimal separator is `.`; grouping separators (`,`, spaces) between
    /// digits are ignored, matching how people paste amounts.
    public static func evaluate(_ input: String) -> Decimal? {
        var parser = Parser(input)
        guard let value = parser.parseExpression(), parser.consumedAll() else { return nil }
        return value
    }

    private struct Parser {
        private let scalars: [Character]
        private var index = 0

        init(_ input: String) { scalars = Array(input) }

        mutating func consumedAll() -> Bool {
            skipSpaces()
            return index >= scalars.count
        }

        // expr := term (('+' | '-') term)*
        mutating func parseExpression() -> Decimal? {
            guard var value = parseTerm() else { return nil }
            while let op = peekOperator(in: ["+", "-"]) {
                advance()
                guard let rhs = parseTerm() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        // term := factor (('*' | '/') factor)*
        private mutating func parseTerm() -> Decimal? {
            guard var value = parseFactor() else { return nil }
            while let op = peekOperator(in: ["*", "/"]) {
                advance()
                guard let rhs = parseFactor() else { return nil }
                if op == "*" {
                    value *= rhs
                } else {
                    guard rhs != 0 else { return nil }   // division by zero
                    value /= rhs
                }
            }
            return value
        }

        // factor := ('+' | '-') factor | '(' expr ')' | number
        private mutating func parseFactor() -> Decimal? {
            skipSpaces()
            guard index < scalars.count else { return nil }
            let c = scalars[index]
            if c == "+" { advance(); return parseFactor() }
            if c == "-" { advance(); return parseFactor().map { -$0 } }
            if c == "(" {
                advance()
                guard let value = parseExpression() else { return nil }
                skipSpaces()
                guard index < scalars.count, scalars[index] == ")" else { return nil }
                advance()
                return value
            }
            return parseNumber()
        }

        private mutating func parseNumber() -> Decimal? {
            skipSpaces()
            var digits = ""
            var sawDigit = false, sawDot = false
            while index < scalars.count {
                let c = scalars[index]
                if c.isNumber {
                    digits.append(c); sawDigit = true; advance()
                } else if c == "." && !sawDot {
                    digits.append(c); sawDot = true; advance()
                } else if c == "," && sawDigit && !sawDot {
                    advance()               // ignore comma grouping between integer digits
                } else {
                    break
                }
            }
            guard sawDigit else { return nil }
            return Decimal(string: digits)
        }

        private mutating func peekOperator(in ops: Set<Character>) -> Character? {
            skipSpaces()
            guard index < scalars.count, ops.contains(scalars[index]) else { return nil }
            return scalars[index]
        }

        private mutating func skipSpaces() {
            while index < scalars.count, scalars[index] == " " { index += 1 }
        }
        private mutating func advance() { index += 1 }
    }
}

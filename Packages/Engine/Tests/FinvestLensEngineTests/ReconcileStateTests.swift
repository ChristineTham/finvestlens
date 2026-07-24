//
//  ReconcileStateTests.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

@Suite("Reconcile state")
struct ReconcileStateTests {

    @Test("GnuCash letter codes round-trip through rawValue")
    func rawValues() {
        #expect(ReconcileState.allCases.map(\.rawValue) == ["n", "c", "y", "f", "v"])
        for state in ReconcileState.allCases {
            #expect(ReconcileState(rawValue: state.rawValue) == state)
        }
        #expect(ReconcileState(rawValue: "x") == nil)
        #expect(ReconcileState(rawValue: "N") == nil)   // codes are lowercase
    }

    @Test("Labels spell the states out")
    func labels() {
        #expect(ReconcileState.allCases.map(\.label) ==
                ["Not Reconciled", "Cleared", "Reconciled", "Frozen", "Voided"])
    }

    @Test("Voided is not settable from a register")
    func settable() {
        #expect(ReconcileState.settableInRegister ==
                [.notReconciled, .cleared, .reconciled, .frozen])
        #expect(!ReconcileState.settableInRegister.contains(.voided))
    }

    @Test("Encodes as the letter code")
    func codable() throws {
        let data = try JSONEncoder().encode([ReconcileState.reconciled])
        #expect(String(data: data, encoding: .utf8) == #"["y"]"#)
        let back = try JSONDecoder().decode([ReconcileState].self, from: Data(#"["f"]"#.utf8))
        #expect(back == [.frozen])
    }
}

@Suite("Recurrence first-occurrence weekend agreement")
struct FirstOccurrenceWeekendTests {

    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    @Test("occurrences() lists the same weekend-adjusted start next(after:) answers")
    func startAgreement() {
        // Sat 15 Mar 2025, monthly, adjust back → Fri 14 Mar.
        let rule = Recurrence(period: .monthly, interval: 1,
                              startDate: utc(2025, 3, 15), weekendAdjust: .back)
        let fromNext = rule.next(after: utc(2025, 1, 1))
        let fromList = rule.occurrences(since: nil, through: utc(2025, 3, 31)).first
        #expect(fromNext == utc(2025, 3, 14))
        #expect(fromList == fromNext)
    }
}

@Suite("Loan degenerate terms")
struct LoanDegenerateTests {
    @Test("A zero-length term has zero interest, not minus the principal")
    func zeroTerm() {
        let loan = LoanCalculator(principal: 10_000, annualRatePercent: 5, years: 0)
        #expect(loan.schedule().isEmpty)
        #expect(loan.totalInterest == 0)
    }
}

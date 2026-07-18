//
//  SavingsGoalTests.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

@Suite("Savings goal")
struct SavingsGoalTests {

    @Test("Progress, remaining and completion track saved vs target")
    func progress() {
        var goal = SavingsGoal(name: "Holiday", targetAmount: dec("1000"), savedAmount: dec("250"))
        #expect(goal.fractionComplete == 0.25)
        #expect(goal.remaining == dec("750"))
        #expect(!goal.isComplete)

        goal.savedAmount = dec("1000")
        #expect(goal.isComplete)
        #expect(goal.remaining == 0)
        #expect(goal.fractionComplete == 1)

        // Over-saving clamps progress at 1 and never reports negative remaining.
        goal.savedAmount = dec("1200")
        #expect(goal.fractionComplete == 1)
        #expect(goal.remaining == 0)
    }

    @Test("A goal with no target has zero progress, not a divide-by-zero")
    func noTarget() {
        let goal = SavingsGoal(name: "Open-ended", targetAmount: 0, savedAmount: dec("500"))
        #expect(goal.fractionComplete == 0)
        #expect(!goal.isComplete)
    }

    @Test("Older slots without group/notes/date decode cleanly")
    func backwardCompatibleDecode() throws {
        let json = #"{"id":"\#(GncGUID.random().hexString)","name":"Old","targetAmount":100,"savedAmount":10}"#
        let goal = try JSONDecoder().decode(SavingsGoal.self, from: Data(json.utf8))
        #expect(goal.name == "Old")
        #expect(goal.group == "")
        #expect(goal.targetDate == nil)
    }
}

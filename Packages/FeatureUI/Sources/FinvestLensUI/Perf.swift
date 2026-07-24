//
//  Perf.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The measurement harness the performance review asked for: every hot path
//  is wrapped in `Perf.measure`, so Instruments' os_signpost view shows where
//  a slow interaction spent its time, and a DEBUG build prints any pass that
//  crosses a frame budget — regressions surface in the console during normal
//  development instead of waiting for someone to notice the app feels slow.
//

import os

enum Perf {
    static let signposter = OSSignposter(
        subsystem: "com.hellotham.finvestlensapp", category: "perf")

    /// Wraps a unit of work in a signpost interval. In DEBUG, work that takes
    /// longer than `budget` (default: half a 60Hz frame) is printed with its
    /// duration — quiet when fast, loud the moment something regresses.
    @discardableResult
    static func measure<T>(_ name: StaticString,
                           budget: Duration = .milliseconds(8),
                           _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        #if DEBUG
        let start = ContinuousClock.now
        defer {
            let elapsed = ContinuousClock.now - start
            if elapsed > budget {
                let ms = Double(elapsed.components.seconds) * 1000
                    + Double(elapsed.components.attoseconds) / 1e15
                print("⏱ \(name): \(String(format: "%.1f", ms)) ms")
            }
        }
        #endif
        return try body()
    }

    /// `measure` for the report cache, where the interesting name (the cache
    /// key) is runtime data and so can't be the signpost name.
    @discardableResult
    static func measureReport<T>(_ key: String,
                                 budget: Duration = .milliseconds(8),
                                 _ body: () -> T?) -> T? {
        let state = signposter.beginInterval("report")
        defer { signposter.endInterval("report", state) }
        #if DEBUG
        let start = ContinuousClock.now
        defer {
            let elapsed = ContinuousClock.now - start
            if elapsed > budget {
                let ms = Double(elapsed.components.seconds) * 1000
                    + Double(elapsed.components.attoseconds) / 1e15
                print("⏱ report[\(key)]: \(String(format: "%.1f", ms)) ms")
            }
        }
        #endif
        return body()
    }
}

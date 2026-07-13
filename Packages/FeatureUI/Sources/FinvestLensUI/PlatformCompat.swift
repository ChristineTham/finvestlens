//
//  PlatformCompat.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

extension View {
    /// `.onExitCommand` (Esc) exists only on macOS/tvOS; on iOS sheets are
    /// dismissed by the system (swipe/Done), so the handler is a no-op there.
    @ViewBuilder
    func onEscapeCommand(perform action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onExitCommand(perform: action)
        #else
        self
        #endif
    }
}

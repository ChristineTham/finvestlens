//
//  SharedComponents.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Small shared utilities used across several features.
//

import SwiftUI
#if os(macOS)
import AppKit
import Quartz
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Puts a plain string on the system pasteboard.
enum GeneralPasteboard {
    static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = string
        #endif
    }
}

#if os(macOS)
/// Quick Look embedded in the sidebar (`QLPreviewView`) — the attachment shows
/// itself the moment its transaction is selected, no extra click.
struct EmbeddedQuickLook: NSViewRepresentable {
    let url: URL

    final class Coordinator { var url: URL? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact) ?? QLPreviewView()
        view.shouldCloseWithWindow = false
        context.coordinator.url = url
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        view.previewItem = url as NSURL
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) {
        view.close()
    }
}
#endif

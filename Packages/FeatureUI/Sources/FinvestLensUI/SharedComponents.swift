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

/// The one status overlay (redesign 6.8): a progress chip while a long
/// operation runs, a transient toast when one completes. Sits at the bottom
/// of the main window; every long operation routes here, so feedback has one
/// home instead of per-sheet spinners.
struct StatusOverlay: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            if model.isSaving {
                chip {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Saving…").scaledFont(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            if let progress = model.quoteProgress {
                chip {
                    HStack(spacing: 10) {
                        ProgressView(value: progress)
                            .frame(width: 140)
                        if case .fetching(let what) = model.quoteStatus {
                            Text(what)
                                .scaledFont(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            if let toast = model.toast {
                chip {
                    Label(toast.message, systemImage: icon(for: toast.kind))
                        .scaledFont(.callout)
                        .foregroundStyle(toast.kind == .failure ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                        .lineLimit(2)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 14)
        .animation(.snappy, value: model.toast)
        .animation(.snappy, value: model.quoteProgress == nil)
        .allowsHitTesting(false)
    }

    private func chip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 4, y: 2)
    }

    private func icon(for kind: AppModel.StatusToast.Kind) -> String {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }
}

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

/// P3's compute-off-body wrapper: paints immediately (spinner on first load,
/// stale content while refreshing), then builds the report in a task — the
/// model memoises per (parameters, book revision), so a body pass never
/// computes anything. `key` must change when the parameters or the book do.
struct AsyncReport<Key: Equatable, Value, Content: View>: View {
    let key: Key
    let title: String
    let build: @MainActor () -> Value?
    @ViewBuilder let content: (Value) -> Content

    /// Wrapped so "built, but the report was nil" (no book, nothing to
    /// report) is distinct from "not built yet".
    @State private var built: [Value?] = []

    var body: some View {
        Group {
            if let value = built.first {
                if let value {
                    content(value)
                } else {
                    ContentUnavailableView("Nothing to report", systemImage: "doc.text.magnifyingglass")
                }
            } else {
                ProgressView("Building \(title)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: key) {
            // One runloop turn so the placeholder actually paints before a
            // seconds-long first build (the build itself is main-actor: the
            // engine book is not sendable, and edits race a background read).
            await Task.yield()
            built = [build()]
        }
    }
}

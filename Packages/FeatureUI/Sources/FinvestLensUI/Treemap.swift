//
//  Treemap.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  A squarified treemap (Bruls, Huizing & van Wijk) — Swift Charts has no
//  treemap mark, so tiles are laid out here and drawn as plain rectangles.
//

import SwiftUI

/// One thing to place in a treemap: a weight and how to label it.
struct TreemapItem: Identifiable, Hashable {
    let id: String
    let name: String
    let value: Double
    let detail: String
}

/// A treemap of `items`, tiles sized by value, largest first, coloured by index.
struct Treemap: View {
    let items: [TreemapItem]

    var body: some View {
        GeometryReader { geo in
            let tiles = Self.layout(items, in: CGRect(origin: .zero, size: geo.size))
            ForEach(tiles, id: \.item.id) { tile in
                let showLabel = tile.rect.width > 48 && tile.rect.height > 28
                RoundedRectangle(cornerRadius: 4)
                    .fill(color(for: tile.index).gradient)
                    .overlay(alignment: .topLeading) {
                        if showLabel {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tile.item.name).font(.caption2).fontWeight(.medium)
                                    .lineLimit(1)
                                Text(tile.item.detail).font(.caption2)
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(4)
                            .foregroundStyle(.white)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.background.opacity(0.4)))
                    .frame(width: max(0, tile.rect.width - 2), height: max(0, tile.rect.height - 2))
                    .position(x: tile.rect.midX, y: tile.rect.midY)
                    .help("\(tile.item.name) — \(tile.item.detail)")
            }
        }
    }

    private func color(for index: Int) -> Color {
        // Even hue spread; a fixed set of anchors keeps adjacent tiles distinct.
        let hues: [Double] = [0.58, 0.10, 0.33, 0.78, 0.02, 0.46, 0.88, 0.20, 0.66, 0.13]
        return Color(hue: hues[index % hues.count], saturation: 0.62, brightness: 0.80)
    }

    // MARK: Squarified layout

    struct Tile { let item: TreemapItem; let index: Int; let rect: CGRect }

    static func layout(_ items: [TreemapItem], in bounds: CGRect) -> [Tile] {
        let positive = items.filter { $0.value > 0 }
        guard !positive.isEmpty, bounds.width > 0, bounds.height > 0 else { return [] }
        // Scale values so their sum equals the available area.
        let total = positive.reduce(0) { $0 + $1.value }
        let area = Double(bounds.width * bounds.height)
        var indexed = positive.enumerated().map { (index: $0.offset, item: $0.element,
                                                    area: $0.element.value / total * area) }
        var tiles: [Tile] = []
        var rect = bounds
        var row: [(index: Int, item: TreemapItem, area: Double)] = []

        func shorterSide(_ r: CGRect) -> Double { Double(min(r.width, r.height)) }

        // Worst aspect ratio of a row of areas laid along a side of length `side`.
        func worst(_ areas: [Double], _ side: Double) -> Double {
            guard let mx = areas.max(), let mn = areas.min(), side > 0 else { return .infinity }
            let sum = areas.reduce(0, +)
            let s2 = sum * sum
            let side2 = side * side
            return max(side2 * mx / s2, s2 / (side2 * mn))
        }

        func layoutRow(_ row: [(index: Int, item: TreemapItem, area: Double)], in rect: inout CGRect) {
            let rowArea = row.reduce(0) { $0 + $1.area }
            let horizontal = rect.width >= rect.height
            if horizontal {
                let w = CGFloat(rowArea / Double(rect.height))
                var y = rect.minY
                for cell in row {
                    let h = CGFloat(cell.area / Double(w))
                    tiles.append(Tile(item: cell.item, index: cell.index,
                                      rect: CGRect(x: rect.minX, y: y, width: w, height: h)))
                    y += h
                }
                rect = CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height)
            } else {
                let h = CGFloat(rowArea / Double(rect.width))
                var x = rect.minX
                for cell in row {
                    let w = CGFloat(cell.area / Double(h))
                    tiles.append(Tile(item: cell.item, index: cell.index,
                                      rect: CGRect(x: x, y: rect.minY, width: w, height: h)))
                    x += w
                }
                rect = CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h)
            }
        }

        while !indexed.isEmpty {
            let next = indexed[0]
            let side = shorterSide(rect)
            let rowAreas = row.map(\.area)
            if row.isEmpty || worst(rowAreas + [next.area], side) <= worst(rowAreas, side) {
                row.append(next)
                indexed.removeFirst()
            } else {
                layoutRow(row, in: &rect)
                row = []
            }
        }
        if !row.isEmpty { layoutRow(row, in: &rect) }
        return tiles
    }
}

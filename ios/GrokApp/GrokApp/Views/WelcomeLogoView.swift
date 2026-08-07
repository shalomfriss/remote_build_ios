// Copyright (c) 2026 Pedro Shakour
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Build Buddy welcome wordmark rendered as a two-line dot-matrix display.
struct WelcomeLogoView: View {
    let theme: GrokTheme

    private static let pixelRows = [
        "11110 10001 11111 10000 11110",
        "10001 10001 00100 10000 10001",
        "10001 10001 00100 10000 10001",
        "11110 10001 00100 10000 10001",
        "10001 10001 00100 10000 10001",
        "10001 10001 00100 10000 10001",
        "11110 01110 11111 11111 11110",
        "                             ",
        "11110 10001 11110 11110 10001",
        "10001 10001 10001 10001 10001",
        "10001 10001 10001 10001 01010",
        "11110 10001 10001 10001 00100",
        "10001 10001 10001 10001 00100",
        "10001 10001 10001 10001 00100",
        "11110 01110 11110 11110 00100",
    ]
    private static let columnCount = pixelRows.map(\.count).max() ?? 1
    private static let rowCount = pixelRows.count

    var body: some View {
        Canvas { context, size in
            let cellSize = min(
                size.width / CGFloat(Self.columnCount),
                size.height / CGFloat(Self.rowCount)
            )
            let dotSize = cellSize * 0.62
            let contentWidth = cellSize * CGFloat(Self.columnCount)
            let contentHeight = cellSize * CGFloat(Self.rowCount)
            let originX = (size.width - contentWidth) / 2
            let originY = (size.height - contentHeight) / 2

            for (rowIndex, row) in Self.pixelRows.enumerated() {
                for (columnIndex, pixel) in row.enumerated() {
                    let rect = CGRect(
                        x: originX + CGFloat(columnIndex) * cellSize + (cellSize - dotSize) / 2,
                        y: originY + CGFloat(rowIndex) * cellSize + (cellSize - dotSize) / 2,
                        width: dotSize,
                        height: dotSize
                    )
                    let color = pixel == "1"
                        ? theme.textPrimary
                        : theme.textPrimary.opacity(0.07)
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
            .aspectRatio(
                Double(Self.columnCount) / Double(Self.rowCount),
                contentMode: .fit
            )
            .frame(maxWidth: 360)
            .padding(.horizontal, 24)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Build Buddy")
    }
}

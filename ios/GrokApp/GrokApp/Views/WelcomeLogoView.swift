// Copyright (c) 2026 Pedro Shakour
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Build Buddy welcome wordmark, rendered as one lightweight monospaced block.
struct WelcomeLogoView: View {
    let theme: GrokTheme

    private static let logoText = #"""
       .-----------------------------.
      /                               \
     |        [>_]  BUILD BUDDY        |
      \_______________________________/
           /_/                   \_\
    """#

    var body: some View {
        Text(Self.logoText)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(theme.textPrimary.opacity(0.92))
            .multilineTextAlignment(.center)
            .lineSpacing(1)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("build buddy")
    }
}

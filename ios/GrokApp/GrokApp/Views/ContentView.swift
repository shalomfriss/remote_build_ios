// Copyright (c) 2026 Pedro Shakour
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.screen {
            case .welcome:
                WelcomeView()
            case .onboarding, .settings:
                OnboardingView(isSettings: model.screen == .settings)
            case .pagerSettings:
                PagerSettingsView()
            case .agent:
                AgentWorkspaceView()
            case .dashboard:
                DashboardView()
            case .themePicker:
                ThemePickerView()
            case .filePicker:
                FilePickerView()
            case .sessionPicker:
                SessionPickerView()
            case .changelog:
                ChangelogView()
            }
        }
        .alert("New Project", isPresented: $model.isNamingProject) {
            TextField("Project name", text: $model.projectNameDraft)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {}
            Button("Create", action: model.createNamedProject)
                .disabled(!model.canCreateNamedProject)
        } message: {
            Text("This name will be used for the project folder and Xcode project.")
        }
    }
}

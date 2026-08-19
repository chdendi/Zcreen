import SwiftUI

struct MenuBarView: View {
    @ObservedObject var orchestrator: Orchestrator
    @State private var launchAtLogin = LoginItemManager.isEnabled
    @State private var hoveredButton: String?
    @State private var accessibilityOK = AccessibilityHelper.isTrusted

    var body: some View {
        VStack(spacing: 0) {
            HeaderSection(orchestrator: orchestrator)

            if orchestrator.autoUpdater.updateAvailable {
                UpdateBanner(updater: orchestrator.autoUpdater)
            }

            if let issue = orchestrator.configManager.configIssue {
                ConfigErrorBanner(issue: issue) {
                    orchestrator.configManager.openConfigInEditor()
                }
            }

            ScreenListSection(screens: orchestrator.screenDetector.screens, hoveredButton: $hoveredButton)

            if !orchestrator.lastAction.isEmpty {
                statusSection
            }

            SettingsSection(menuState: orchestrator.menuState, launchAtLogin: $launchAtLogin)
            CaffeinateSection(manager: orchestrator.caffeinateManager, hoveredButton: $hoveredButton)
            FooterSection(updater: orchestrator.autoUpdater, hoveredButton: $hoveredButton)
        }
        .frame(width: 300)
        .onAppear { accessibilityOK = AccessibilityHelper.isTrusted }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            accessibilityOK = AccessibilityHelper.isTrusted
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.green.opacity(0.7))
            Text(orchestrator.lastAction)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

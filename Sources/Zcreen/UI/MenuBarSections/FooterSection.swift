import SwiftUI
import AppKit

struct FooterSection: View {
    @ObservedObject var updater: AutoUpdater
    @Binding var hoveredButton: String?

    var body: some View {
        VStack(spacing: 0) {
            MenuBarHelpers.sectionDivider

            HStack(spacing: 0) {
                footerButton("About") { showAbout() }

                footerDot

                footerButton("Logs") { revealLogs() }

                Spacer()

                if updater.isChecking {
                    ProgressView()
                        .controlSize(.mini)
                        .padding(.horizontal, 4)
                } else {
                    footerButton("Check for Updates") {
                        updater.checkForUpdates()
                    }
                }

                footerDot

                footerButton("Quit", role: .destructive) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.2))
        }
    }

    private func footerButton(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(role == .destructive ? .red.opacity(0.8) : .secondary)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { hoveredButton = title } else { hoveredButton = nil }
        }
    }

    private var footerDot: some View {
        Text("\u{00B7}")
            .font(.system(size: 11))
            .foregroundStyle(.quaternary)
            .padding(.horizontal, 6)
    }

    private func revealLogs() {
        NSWorkspace.shared.activateFileViewerSelecting([FileLogSink.shared.directoryURL])
    }

    private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Zcreen"
        alert.informativeText = "Version 1.2.0\n\nMulti-screen window manager for macOS.\nAutomatically saves and restores window layouts when screens change.\n\nNo configuration needed \u{2014} just plug/unplug your displays."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

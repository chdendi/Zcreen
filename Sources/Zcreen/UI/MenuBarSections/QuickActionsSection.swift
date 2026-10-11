import SwiftUI

struct QuickActionsSection: View {
    @ObservedObject var orchestrator: Orchestrator

    var body: some View {
        VStack(spacing: 0) {
            MenuBarHelpers.sectionDivider

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    actionButton(
                        title: "Save Layout",
                        icon: "square.and.arrow.down"
                    ) {
                        orchestrator.saveCurrentLayout()
                    }

                    actionButton(
                        title: "Restore",
                        icon: "arrow.counterclockwise"
                    ) {
                        orchestrator.restoreCurrentLayout()
                    }
                }

                HStack(spacing: 8) {
                    actionButton(
                        title: "Config File",
                        icon: "slider.horizontal.3"
                    ) {
                        orchestrator.configManager.openConfigInEditor()
                    }

                    actionButton(
                        title: "Snapshots",
                        icon: "folder"
                    ) {
                        orchestrator.configManager.openSnapshotsDirectory()
                    }
                }
                actionButton(title: "Feedback", icon: "bubble.left.and.bubble.right") {
                    FeedbackController.shared.present()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func actionButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

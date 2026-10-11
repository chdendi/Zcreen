import SwiftUI
import AppKit

struct HeaderSection: View {
    @ObservedObject var orchestrator: Orchestrator
    @State private var feedbackGesture = FeedbackGesture()

    private var screenDetector: ScreenDetector { orchestrator.screenDetector }
    private var snapshotStore: LayoutSnapshotStore { orchestrator.snapshotStore }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.linearGradient(
                            colors: [.blue.opacity(0.7), .purple.opacity(0.6)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 32, height: 32)
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                }
                .onTapGesture {
                    if feedbackGesture.tap() { FeedbackController.shared.present() }
                }
                .help("Click five times to open feedback")

                VStack(alignment: .leading, spacing: 2) {
                    Text("Zcreen")
                        .font(.system(size: 13, weight: .semibold))

                    let appCount = snapshotStore.savedAppNames(for: screenDetector.profileKey).count
                    Button {
                        guard let fileURL = snapshotStore.snapshotFileURL(for: screenDetector.profileKey) else { return }
                        NSWorkspace.shared.open(fileURL)
                    } label: {
                        HStack(spacing: 3) {
                            Text("\(screenDetector.screenCount) screen\(screenDetector.screenCount == 1 ? "" : "s") \u{00B7} \(appCount) app\(appCount == 1 ? "" : "s") saved")
                            Image(systemName: "doc.text")
                                .font(.system(size: 7, weight: .semibold))
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Open saved layout file")
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.quaternary.opacity(0.3))
        }
    }
}

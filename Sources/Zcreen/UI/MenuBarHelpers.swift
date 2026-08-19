import SwiftUI

/// Shared UI helpers for MenuBar sections
enum MenuBarHelpers {
    static let caffeinateActiveColor = Color(red: 0.55, green: 0.36, blue: 0.96)

    static var sectionDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 1)
    }

    static func screenColor(_ index: Int) -> Color {
        [.blue, .purple, .teal, .orange, .pink][index % 5]
    }

    static func resolutionBadge(_ screen: ScreenInfo) -> some View {
        Text("\(Int(screen.frame.width)) \u{00D7} \(Int(screen.frame.height))")
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.secondary.opacity(0.1))
            .clipShape(Capsule())
            .foregroundStyle(.secondary)
    }

    static func metaBadge(_ text: String, icon: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 7))
            Text(text)
                .font(.system(size: 9, weight: .medium))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(.secondary.opacity(0.1))
        .clipShape(Capsule())
        .foregroundStyle(.secondary)
    }
}

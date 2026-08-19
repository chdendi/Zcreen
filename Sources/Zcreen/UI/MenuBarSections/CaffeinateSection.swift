import SwiftUI

struct CaffeinateSection: View {
    @ObservedObject var manager: CaffeinateManager
    @Binding var hoveredButton: String?

    private let activeColor = MenuBarHelpers.caffeinateActiveColor

    var body: some View {
        VStack(spacing: 0) {
            MenuBarHelpers.sectionDivider

            if manager.isActive {
                activeView
            } else {
                inactiveView
            }
        }
    }

    private var activeView: some View {
        HStack(spacing: 10) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 11))
                .foregroundStyle(activeColor)
                .frame(width: 16)
            Text("Caffeinate")
                .font(.system(size: 12, weight: .medium))
            Text(manager.isIndefinite ? "Until stopped" : "\(manager.remainingMinutes) min")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(activeColor.opacity(0.12))
                .foregroundStyle(activeColor)
                .clipShape(Capsule())
            Spacer()
            Button {
                manager.deactivate()
            } label: {
                Text("Stop")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.red.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var inactiveView: some View {
        HStack(spacing: 10) {
            Image(systemName: "cup.and.saucer")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text("Caffeinate")
                .font(.system(size: 12))
            Spacer()
            HStack(spacing: 4) {
                ForEach(CaffeinateManager.durations, id: \.minutes) { item in
                    Button {
                        manager.activate(minutes: item.minutes)
                    } label: {
                        Text(item.label)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(hoveredButton == "caf-\(item.minutes)" ? 0.1 : 0.05))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .onHover { h in hoveredButton = h ? "caf-\(item.minutes)" : nil }
                }

                Button {
                    manager.activateIndefinitely()
                } label: {
                    Text("∞")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(activeColor.opacity(hoveredButton == "caf-indefinite" ? 0.18 : 0.09))
                        .foregroundStyle(activeColor)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Keep awake until Stop is clicked")
                .onHover { h in hoveredButton = h ? "caf-indefinite" : nil }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

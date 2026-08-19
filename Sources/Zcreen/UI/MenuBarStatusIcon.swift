import SwiftUI

enum MenuBarStatusIcon {
    static func symbolName(isActive: Bool) -> String {
        isActive ? "cup.and.saucer.fill" : "rectangle.3.group"
    }
}

struct MenuBarStatusIconView: View {
    @ObservedObject var caffeinateManager: CaffeinateManager

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: MenuBarStatusIcon.symbolName(isActive: caffeinateManager.isActive))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(caffeinateManager.isActive ? MenuBarHelpers.caffeinateActiveColor : .primary)

            if caffeinateManager.isActive {
                Circle()
                    .fill(MenuBarHelpers.caffeinateActiveColor)
                    .frame(width: 7, height: 7)
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 4, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .offset(x: 3, y: 2)
            }
        }
        .frame(width: 18, height: 16)
        .help(caffeinateManager.isActive ? "Caffeinate is active" : "Zcreen")
    }
}

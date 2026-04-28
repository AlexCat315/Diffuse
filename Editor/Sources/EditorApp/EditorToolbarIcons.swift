import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import Foundation

// MARK: - Toolbar Text Button

struct ToolbarTextButton: View {
    let title: String

    var body: some View {
        ToolbarButtonChrome(title: title)
    }
}

// MARK: - Toolbar Action Button

struct ToolbarActionButton: View {
    let title: String
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            ToolbarButtonChrome(title: title,
                                minWidth: title.count > 8 ? 92 : 68)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Toolbar State Button

struct ToolbarStateButton: View {
    let title: String
    let isActive: Bool
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            ToolbarButtonChrome(title: title,
                                foreground: isActive ? .onAccent : .onSurface,
                                background: isActive ? .accent : .surfaceSunken,
                                minWidth: title.count > 7 ? 88 : 68)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Toolbar Button Chrome

struct ToolbarButtonChrome: View {
    let title: String
    var foreground: SemanticColorRef = .onSurface
    var background: SemanticColorRef = .surfaceSunken
    var minWidth: Float = 68

    var body: some View {
        Box(direction: .row, alignItems: .center, justifyContent: .center) {
            Text(title, lineLimit: 1)
                .font(.caption)
                .foregroundColor(foreground)
        }
        .frame(height: 34, minWidth: minWidth)
        .padding(horizontal: 8, vertical: 0)
        .background(background)
        .cornerRadius(4)
        .clipped()
    }
}
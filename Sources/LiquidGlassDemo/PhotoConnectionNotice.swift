import SwiftUI

struct PhotoConnectionNotice: View {
    let issue: PhotoConnectionIssue
    let isChecking: Bool
    let onRetry: () -> Void
    let onSettings: () -> Void

    @Environment(ThemeStore.self) private var theme

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(issue.title)
                    .font(Typography.label)
                    .foregroundStyle(theme.textPrimary)
                Text(issue.message)
                    .font(Typography.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Fixed gap, not a flexible spacer: the notice should hug its content
            // and give up width when the window is narrow, instead of holding a
            // constant length that only makes sense at one window size.
            Spacer()
                .frame(width: 24)
            if isChecking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Checking connection")
            }
            if case .model = issue {
                Button("Models", action: onSettings)
            }
            Button("Check Again", action: onRetry)
                .disabled(isChecking)
        }
        .buttonStyle(ConnectionNoticeButtonStyle())
        .padding(16)
        .background(theme.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.orange.opacity(0.3), lineWidth: 1) }
        .shadow(color: .black.opacity(0.08), radius: 14, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Connection notice")
    }
}

private struct ConnectionNoticeButtonStyle: ButtonStyle {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.control)
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(theme.accent.opacity(hovering ? 0.14 : 0.08), in: Capsule())
            .overlay { Capsule().strokeBorder(theme.accent.opacity(0.2), lineWidth: 1) }
            .contentShape(Capsule())
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.65 : 1)
            .pointerStyle(.link)
            .onHover { hovering = $0 }
    }
}

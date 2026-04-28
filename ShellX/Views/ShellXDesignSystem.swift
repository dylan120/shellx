import SwiftUI

enum ShellXUI {
    static let sectionCornerRadius: CGFloat = 8
    static let controlCornerRadius: CGFloat = 6
    static let compactSpacing: CGFloat = 8
    static let contentSpacing: CGFloat = 12
    static let sectionSpacing: CGFloat = 16

    static var sectionBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    static var subtleBackground: Color {
        Color(nsColor: .textBackgroundColor)
    }

    static var separator: Color {
        Color(nsColor: .separatorColor)
    }

    static func statusColor(_ state: TerminalConnectionState) -> Color {
        switch state {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .failed:
            return .red
        case .disconnected, .idle:
            return .secondary
        }
    }

    static func scriptStatusColor(_ status: ScriptExecutionStatus) -> Color {
        switch status {
        case .pending:
            return .secondary
        case .running:
            return .orange
        case .succeeded:
            return .green
        case .failed:
            return .red
        }
    }
}

struct ShellXSection<Content: View>: View {
    let title: String?
    let subtitle: String?
    let content: Content

    init(
        _ title: String? = nil,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ShellXUI.contentSpacing) {
            if title != nil || subtitle != nil {
                VStack(alignment: .leading, spacing: 3) {
                    if let title {
                        Text(title)
                            .font(.headline)
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ShellXUI.sectionBackground, in: RoundedRectangle(cornerRadius: ShellXUI.sectionCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: ShellXUI.sectionCornerRadius)
                .strokeBorder(ShellXUI.separator.opacity(0.65), lineWidth: 1)
        }
    }
}

struct ShellXInfoRow: View {
    let title: String
    let value: String
    var systemImage: String?
    var isMonospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)
            Text(value)
                .font(isMonospaced ? .system(.body, design: .monospaced) : .body)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

struct ShellXTagChip: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    var systemImage: String?
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
            }
            Text(title)
                .lineLimit(1)
            if let onRemove {
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("移除标签")
            }
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .foregroundStyle(tagForegroundColor)
        .background(tagBackgroundColor, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(tagBorderColor, lineWidth: 1)
        }
    }

    private var tagForegroundColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : .primary
    }

    private var tagBackgroundColor: Color {
        Color.accentColor.opacity(colorScheme == .dark ? 0.25 : 0.10)
    }

    private var tagBorderColor: Color {
        Color.accentColor.opacity(colorScheme == .dark ? 0.36 : 0.20)
    }
}

struct ShellXStatusPill: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(color.opacity(0.22), lineWidth: 1)
            }
    }
}

struct ShellXEmptyState: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

struct ShellXPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(.white)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: ShellXUI.controlCornerRadius))
    }
}

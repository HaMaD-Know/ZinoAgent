import SwiftUI
import UIKit

/// Restrained, native-feeling design tokens for ZinoAgent 2.0 across Light & Dark mode.
public enum ZinoTheme {
    public static let accent = Color.accentColor
    public static let surfacePrimary = Color(uiColor: .systemBackground)
    public static let surfaceSecondary = Color(uiColor: .secondarySystemBackground)
    public static let surfaceTertiary = Color(uiColor: .tertiarySystemBackground)
    public static let surfaceGrouped = Color(uiColor: .systemGroupedBackground)
    public static let border = Color(uiColor: .separator).opacity(0.45)

    public static let statusPositive = Color(uiColor: .systemGreen)
    public static let statusWarning = Color(uiColor: .systemOrange)
    public static let statusCritical = Color(uiColor: .systemRed)
    public static let statusInfo = Color(uiColor: .systemBlue)

    public enum Spacing {
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let sm: CGFloat = 12
        public static let md: CGFloat = 16
        public static let lg: CGFloat = 24
        public static let xl: CGFloat = 32
    }

    public enum Radius {
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
    }
}

public struct ZinoCardModifier: ViewModifier {
    let padding: CGFloat

    public init(padding: CGFloat = ZinoTheme.Spacing.md) {
        self.padding = padding
    }

    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(ZinoTheme.surfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: ZinoTheme.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ZinoTheme.Radius.md, style: .continuous)
                    .stroke(ZinoTheme.border, lineWidth: 0.75)
            )
    }
}

public extension View {
    func zinoCard(padding: CGFloat = ZinoTheme.Spacing.md) -> some View {
        modifier(ZinoCardModifier(padding: padding))
    }
}

public struct StatusBadge: View {
    public let label: String
    public let icon: String?
    public let tint: Color

    public init(_ label: String, icon: String? = nil, tint: Color = ZinoTheme.statusInfo) {
        self.label = label
        self.icon = icon
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2.weight(.semibold))
            }
            Text(label)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(tint)
        .background(tint.opacity(0.12))
        .clipShape(Capsule())
    }
}

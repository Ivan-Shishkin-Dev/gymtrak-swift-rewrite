import SwiftUI

/// The PWA's dark palette, one-for-one.
enum Theme {
    static let bg = Color(hex: 0x0B0B0C)
    static let card = Color(hex: 0x151517)
    static let cardBorder = Color.white.opacity(0.065)
    static let pillBorder = Color.white.opacity(0.1)
    static let text = Color(hex: 0xF2F2EF)
    static let sub = Color(hex: 0x9A9A96)
    static let faint = Color(hex: 0x73736F)
    static let dim = Color(hex: 0x62625F)
    static let future = Color(hex: 0x3D3D42)
    static let volt = Color(hex: 0xD2F56F)
    static let onVolt = Color(hex: 0x171B09)
    static let voltTint = Color(hex: 0xD2F56F).opacity(0.09)
    static let run = Color(hex: 0x7CC4FF)
    static let runTint = Color(hex: 0x7CC4FF).opacity(0.09)
    static let track = Color.white.opacity(0.1)
    static let separator = Color.white.opacity(0.06)
    static let value = Color(hex: 0xD9D9DE)
    static let amber = Color(hex: 0xF5B945)
    static let red = Color(hex: 0xFF5A5A)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension Font {
    /// Condensed bold display face (stands in for Barlow Semi Condensed).
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight).width(.condensed)
    }

    /// Small monospaced eyebrow label.
    static let eyebrow = Font.system(size: 11, weight: .medium, design: .monospaced)
}

struct CardStyle: ViewModifier {
    var radius: CGFloat = 20
    var padding: CGFloat = 20
    var border: Color = Theme.cardBorder

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(border))
    }
}

extension View {
    func card(radius: CGFloat = 20, padding: CGFloat = 20, border: Color = Theme.cardBorder) -> some View {
        modifier(CardStyle(radius: radius, padding: padding, border: border))
    }

    func eyebrow(_ color: Color = Theme.dim) -> some View {
        font(.eyebrow).tracking(1.3).foregroundStyle(color)
    }
}

/// Big filled volt button ("Start Upper A", "Done set").
struct VoltButtonStyle: ButtonStyle {
    var quiet = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: quiet ? 15 : 16, weight: .bold))
            .frame(maxWidth: .infinity)
            .frame(height: quiet ? 48 : 52)
            .foregroundStyle(quiet ? Theme.text : Theme.onVolt)
            .background(quiet ? Color.clear : Theme.volt, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(quiet ? Theme.pillBorder : .clear))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Outlined pill/chip button.
struct PillButtonStyle: ButtonStyle {
    var active = false
    var height: CGFloat = 36
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(height: height)
            .foregroundStyle(active ? Theme.volt : Theme.text)
            .background(active ? Theme.voltTint : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(active ? Theme.volt : Theme.pillBorder))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Dashed "+ Add set" / "+ Add exercise" button.
struct DashedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(Theme.sub)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.pillBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

import SwiftUI
import Observation

/// The user's look: matte black by default, with any accent color they like.
@MainActor
@Observable
final class Appearance {
    static let shared = Appearance()

    struct Preset: Identifiable, Hashable {
        let id: String
        let name: String
        let hex: UInt32
    }

    /// "matte" is the Batman default: graphite surfaces, near-white accent.
    static let presets: [Preset] = [
        .init(id: "matte", name: "Matte", hex: 0xE8E8EA),
        .init(id: "green", name: "Green", hex: 0x34C759),
        .init(id: "blue", name: "Blue", hex: 0x0A84FF),
        .init(id: "purple", name: "Purple", hex: 0xBF5AF2),
        .init(id: "pink", name: "Pink", hex: 0xFF375F),
        .init(id: "red", name: "Red", hex: 0xFF453A),
        .init(id: "orange", name: "Orange", hex: 0xFF9F0A),
        .init(id: "gold", name: "Gold", hex: 0xD4AF37),
    ]

    /// Preset id, or "custom".
    var accentID: String { didSet { UserDefaults.standard.set(accentID, forKey: "gt_accent") } }
    var customHex: UInt32 { didSet { UserDefaults.standard.set(Int(customHex), forKey: "gt_accent_custom") } }
    /// Always dark (matte black) vs follow the phone's light/dark setting.
    var matteBackground: Bool { didSet { UserDefaults.standard.set(matteBackground, forKey: "gt_matte") } }

    private init() {
        let d = UserDefaults.standard
        accentID = d.string(forKey: "gt_accent") ?? "matte"
        customHex = UInt32(d.integer(forKey: "gt_accent_custom") == 0 ? 0x34C759 : d.integer(forKey: "gt_accent_custom"))
        matteBackground = d.object(forKey: "gt_matte") as? Bool ?? true
    }

    var isMatte: Bool { accentID == "matte" }

    var accent: Color {
        if accentID == "custom" { return Color(hex: customHex) }
        return Color(hex: (Self.presets.first { $0.id == accentID } ?? Self.presets[0]).hex)
    }

    /// Set from the system color picker.
    func setCustom(_ color: Color) {
        customHex = color.hexValue
        accentID = "custom"
    }
}

/// Color roles. Read through `Appearance`, so every screen updates when the accent changes.
@MainActor
enum Theme {
    /// Accent for buttons, icons and highlights.
    static var lift: Color { Appearance.shared.accent }
    /// Text/icons drawn on top of an accent fill.
    static var onLift: Color { lift.isLight ? .black : .white }
    /// Big colored surfaces (the Today card, icon badges). Graphite in matte mode.
    static var surface: Color { Appearance.shared.isMatte ? Color(hex: 0x2C2C2E) : lift }
    static var onSurface: Color { surface.isLight ? .black : .white }
    /// Runs stay blue so they never look like lifts — unless blue *is* the accent.
    static var run: Color { Appearance.shared.accentID == "blue" ? .cyan : .blue }
    static let warning = Color.orange
    /// Dark backdrop for the splash and sign-in screens.
    static var backdrop: LinearGradient {
        LinearGradient(colors: [surface.mix(with: .black, by: Appearance.shared.isMatte ? 0.35 : 0.6), .black],
                       startPoint: .top, endPoint: .bottom)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    /// RGB as 0xRRGGBB.
    var hexValue: UInt32 {
        let c = UIColor(self).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }

    /// True when black text reads better on this color than white.
    var isLight: Bool {
        let h = hexValue
        let r = Double((h >> 16) & 0xFF) / 255, g = Double((h >> 8) & 0xFF) / 255, b = Double(h & 0xFF) / 255
        return 0.299 * r + 0.587 * g + 0.114 * b > 0.62
    }
}

/// Settings-app style icon: a symbol on a colored rounded square.
struct IconBadge: View {
    let systemName: String
    let color: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(color.isLight ? .black : .white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

extension Font {
    /// Big rounded numbers for loads, reps and timers.
    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

/// The app logo, drawn live so it follows the chosen accent.
struct LogoView: View {
    var size: CGFloat = 60

    var body: some View {
        Image(systemName: "dumbbell.fill")
            .font(.system(size: size * 0.46, weight: .bold))
            .rotationEffect(.degrees(-45))
            .foregroundStyle(Appearance.shared.isMatte ? Theme.lift : Theme.onSurface)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [Theme.surface.mix(with: .white, by: 0.1), Theme.surface.mix(with: .black, by: 0.45)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

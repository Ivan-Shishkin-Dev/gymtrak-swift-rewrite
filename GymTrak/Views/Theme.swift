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

/// Notion-style property icon: a plain gray symbol, no colored tile. `color` is kept so call sites
/// can still say what the icon is about; only runs keep their tint.
struct IconBadge: View {
    let systemName: String
    let color: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.55, weight: .regular))
            .foregroundStyle(Page.secondary)
            .frame(width: size, height: size)
    }
}

// MARK: - Page (Notion-style)

/// Notion's palette: flat page, warm gray text, hairline dividers. Light and dark.
enum Page {
    static let bg = Color(light: 0xFFFFFF, dark: 0x191919)
    static let text = Color(light: 0x37352F, dark: 0xD3D3D3)
    static let secondary = Color(light: 0x787774, dark: 0x9B9A97)
    static let tertiary = Color(light: 0xB4B4B0, dark: 0x5A5A5A)
    static let divider = Color(light: 0xE9E9E7, dark: 0x2F2F2F)
    static let fill = Color(light: 0xF1F1EF, dark: 0x252525)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { $0.userInterfaceStyle == .dark ? UIColor(Color(hex: dark)) : UIColor(Color(hex: light)) })
    }
}

/// "Label    value" — Notion's property row.
struct PropertyRow<Value: View>: View {
    let icon: String
    let label: String
    @ViewBuilder var value: Value

    /// Top-aligned with a one-line-tall icon box, so label and value always start on the same line
    /// (baseline alignment drifted when a value held a progress bar or a chevron).
    @ScaledMetric(relativeTo: .body) private var line: CGFloat = 22

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Page.secondary)
                .frame(width: 20, height: line)
            Text(label).foregroundStyle(Page.secondary).lineLimit(1)
                .frame(width: 104, height: line, alignment: .leading)
            value.foregroundStyle(Page.text)
                .frame(maxWidth: .infinity, minHeight: line, alignment: .leading)
        }
        .font(.body)
        .padding(.vertical, 7)
    }
}

/// A page section: heading over a hairline, like a Notion H2.
struct PageSection<Content: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(Page.divider).frame(height: 1).padding(.bottom, 8)
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title3.weight(.bold)).foregroundStyle(Page.text)
                Spacer()
                trailing.font(.subheadline).foregroundStyle(Page.secondary)
            }
            content
        }
    }
}

/// Small filter pill.
struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(selected ? Page.bg : Page.text)
                .background(selected ? Page.text : Page.fill, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The one strong button on a page: text-colored fill.
struct PrimaryButton: View {
    let title: String
    let icon: String
    var muted = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.headline)
                .frame(maxWidth: .infinity).frame(height: 48)
                .foregroundStyle(muted ? Page.text : Page.bg)
                .background(muted ? Page.fill : Page.text, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// Flat page background for lists and forms.
    func pageBackground() -> some View {
        scrollContentBackground(.hidden).background(Page.bg)
    }
}

extension Font {
    /// Big rounded numbers for loads, reps and timers.
    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

extension View {
    /// Puts the screen's big title in the top-left of the nav bar row (beside the trailing buttons)
    /// instead of a large title underneath, so the top of the screen isn't empty.
    func topLeftTitle(_ title: String, subtitle: String? = nil) -> some View {
        navigationTitle(title)                      // still used for the back button
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbarBackground(Page.bg, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 30, weight: .bold)).lineLimit(1).fixedSize()
                        if let subtitle {
                            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        }
                    }
                    .accessibilityAddTraits(.isHeader)
                }
                .sharedBackgroundVisibility(.hidden)
            }
    }
}

/// Top-left arrow that closes a sheet, matching the back arrow on pushed screens.
struct BackButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button { dismiss() } label: { Image(systemName: "chevron.left") }
            .accessibilityLabel("Back")
    }
}

import AppKit
import SwiftUI

extension Color {
    /// A color that follows the window's light or dark appearance.
    static func dynamic(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

enum Theme {
    static let iris = Color(nsColor: NSColor(hex: 0x7C5CFF))
    static let cyan = Color(nsColor: NSColor(hex: 0x22D3EE))
    static let pink = Color(nsColor: NSColor(hex: 0xF472B6))
    static let brand = LinearGradient(colors: [iris, cyan], startPoint: .topLeading, endPoint: .bottomTrailing)

    static let window = Color.dynamic(light: 0xF4F4F8, dark: 0x0C0D14)
    static let pane = Color.dynamic(light: 0xFFFFFF, dark: 0x12131D)
    static let paneBorder = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.08)
    static let gutterText = Color.dynamic(light: 0x9A9AB0, dark: 0x5E6078)
    static let text = Color.dynamic(light: 0x1B1C2A, dark: 0xE4E5F1)
    static let subtleFill = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.035, darkAlpha: 0.04)

    static let added = Color.dynamic(light: 0x059669, dark: 0x34D399)
    static let addedRow = Color.dynamic(light: 0x10B981, dark: 0x10B981, lightAlpha: 0.10, darkAlpha: 0.12)
    static let addedWord = Color.dynamic(light: 0x10B981, dark: 0x10B981, lightAlpha: 0.30, darkAlpha: 0.36)

    static let removed = Color.dynamic(light: 0xE11D48, dark: 0xFB7185)
    static let removedRow = Color.dynamic(light: 0xF43F5E, dark: 0xF43F5E, lightAlpha: 0.09, darkAlpha: 0.12)
    static let removedWord = Color.dynamic(light: 0xF43F5E, dark: 0xF43F5E, lightAlpha: 0.26, darkAlpha: 0.36)

    static let changed = Color.dynamic(light: 0xD97706, dark: 0xFBBF24)

    static func code(size: Double) -> Font { .system(size: size, design: .monospaced) }
}

/// Two sets of rings drifting over each other: the moiré that gives the app its name.
struct MoireBackground: View {
    var ringCount = 46
    var opacity = 0.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let radius = max(size.width, size.height) * 0.9
                let spacing = radius / Double(ringCount)
                let drift = sin(time * 0.25) * spacing * 3.5
                let centers = [
                    CGPoint(x: size.width * 0.5 - spacing * 2 + drift, y: size.height * 0.48),
                    CGPoint(x: size.width * 0.5 + spacing * 2 - drift, y: size.height * 0.52 + cos(time * 0.2) * spacing),
                ]
                let colors = [Theme.iris, Theme.cyan]
                for (center, color) in zip(centers, colors) {
                    var rings = Path()
                    for index in 1...ringCount {
                        let r = Double(index) * spacing
                        rings.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                    }
                    context.stroke(rings, with: .color(color.opacity(opacity)), lineWidth: spacing * 0.42)
                }
            }
        }
        .mask(RadialGradient(colors: [.black, .black.opacity(0)], center: .center, startRadius: 40, endRadius: 520))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Diagonal stripes for the empty half of a row whose line exists on one side only.
struct Hatching: View {
    var color: Color

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let step = 7.0
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += step
            }
            context.stroke(path, with: .color(color), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// A small rounded label with a colored dot, used for the change counts.
struct Chip: View {
    var text: String
    var color: Color
    var systemImage: String?

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
            } else {
                Circle().frame(width: 6, height: 6)
            }
            Text(text).font(.system(size: 11, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(color.opacity(0.12), in: Capsule())
    }
}

import SwiftUI
import WatchKit

/// Sizes in the watch pages are drawn for the 49 mm screen (205 pt wide) and scaled down for
/// smaller cases, so the 41 mm layout keeps the same proportions.
enum WatchLayout {
    static let scale: CGFloat = min(1, WKInterfaceDevice.current().screenBounds.width / 205)

    static func pt(_ value: CGFloat) -> CGFloat { (value * scale).rounded() }
}

/// Score colours as the iPhone draws them. The watch target doesn't link StrandDesign, so the
/// recovery and strain stops are repeated here; keep them in step with `StrandPalette`.
enum WatchScoreColor {
    struct Stop {
        let location: Double
        let r: Double, g: Double, b: Double

        init(_ location: Double, _ hex: UInt32) {
            self.location = location
            r = Double((hex >> 16) & 0xFF) / 255
            g = Double((hex >> 8) & 0xFF) / 255
            b = Double(hex & 0xFF) / 255
        }
    }

    static let chargeStops = [
        Stop(0.00, 0xFF4F73),   // depleted
        Stop(0.30, 0xF5A623),   // low
        Stop(0.55, 0xE8C24B),   // moderate
        Stop(0.78, 0x18C98B),   // primed
        Stop(1.00, 0x2FE6A8)    // peak
    ]
    static let effortStops = [
        Stop(0.00, 0xE8B04B),
        Stop(0.33, 0xE8743B),
        Stop(0.66, 0xE0476B),
        Stop(1.00, 0xC13AC1)
    ]
    /// StrandPalette.metricPurple
    static let rest = Color(red: 0xA8 / 255, green: 0x79 / 255, blue: 0xFF / 255)
    /// StrandPalette.metricRose
    static let rose = Color(red: 0xFF / 255, green: 0x4F / 255, blue: 0x73 / 255)
    /// StrandPalette.metricCyan
    static let cyan = Color(red: 0x2F / 255, green: 0xC7 / 255, blue: 0xFF / 255)
    /// The elapsed-time yellow watchOS uses for workouts.
    static let timer = Color(red: 0xE8 / 255, green: 0xC2 / 255, blue: 0x4B / 255)
    static let track = Color(white: 0.15)

    /// Blend between the two stops around the score, as `StrandPalette.sample` does on the phone.
    static func sample(_ stops: [Stop], at score: Int) -> Color {
        let t = Double(max(0, min(100, score))) / 100
        guard let upper = stops.firstIndex(where: { $0.location >= t }) else {
            let last = stops[stops.count - 1]
            return Color(red: last.r, green: last.g, blue: last.b)
        }
        guard upper > 0 else { return Color(red: stops[0].r, green: stops[0].g, blue: stops[0].b) }
        let a = stops[upper - 1], b = stops[upper]
        let k = (t - a.location) / (b.location - a.location)
        return Color(red: a.r + (b.r - a.r) * k, green: a.g + (b.g - a.g) * k, blue: a.b + (b.b - a.b) * k)
    }

    static func charge(_ score: Int) -> Color { sample(chargeStops, at: score) }
    static func effort(_ score: Int) -> Color { sample(effortStops, at: score) }
}

/// A score ring: the value inside, the arc the score's colour, grey with "–" when there is no value.
struct WatchScoreRing: View {
    let name: String
    let value: Int?
    let color: Color
    let diameter: CGFloat
    let lineWidth: CGFloat
    let fontSize: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(WatchScoreColor.track, lineWidth: lineWidth)
            if let value {
                Circle()
                    .trim(from: 0, to: CGFloat(max(0, min(100, value))) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(value.map(String.init) ?? "–")
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(value == nil ? Color.secondary : Color.primary)
                .minimumScaleFactor(0.7)
                .padding(lineWidth + 2)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value.map { "\(name) \($0) out of 100" } ?? "\(name) not available")
    }
}

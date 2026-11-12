import SwiftUI

/// Colours from the Figma file (Reel > Editor).
enum Palette {
    static let window = Color(red: 0.075, green: 0.075, blue: 0.085)
    static let panel = Color(red: 0.105, green: 0.105, blue: 0.118)
    static let raised = Color(red: 0.15, green: 0.15, blue: 0.165)
    static let red = Color(red: 0.89, green: 0.24, blue: 0.2)
    static let zoom = Color(red: 0.55, green: 0.45, blue: 0.98)
    static let clip = Color(red: 0.98, green: 0.78, blue: 0.3)
    static let ink = Color(red: 0.08, green: 0.08, blue: 0.09)
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Slim slider: 4 pt track, 14 pt knob, label and value above.
struct ReelSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.0f", $0) }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(format(value)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.white.opacity(0.5))
            }
            GeometryReader { g in
                let frac = CGFloat((value - range.lowerBound) / max(range.upperBound - range.lowerBound, 1e-9))
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12)).frame(height: 4)
                    Capsule().fill(.white.opacity(0.85)).frame(width: max(0, frac * g.size.width), height: 4)
                    Circle().fill(.white).frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .offset(x: frac * (g.size.width - 14))
                }
                .frame(height: 14)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    let f = min(max((v.location.x - 7) / max(g.size.width - 14, 1), 0), 1)
                    value = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                })
            }
            .frame(height: 14)
        }
    }
}

/// Pill-shaped segmented control.
struct Segmented<T: Hashable>: View {
    let items: [(T, String)]
    @Binding var selection: T
    var fill = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { item in
                let on = item.0 == selection
                Button { selection = item.0 } label: {
                    Text(item.1).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(on ? 1 : 0.6))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .frame(maxWidth: fill ? .infinity : nil)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(on ? 0.14 : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.06)))
    }
}

struct PanelToggle: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(Palette.zoom)
    }
}

struct PillButton: View {
    let title: String
    var symbol: String?
    var prominent = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .medium)) }
                Text(title).font(.system(size: 12, weight: prominent ? .semibold : .medium))
            }
            .foregroundStyle(prominent ? Palette.ink : .white.opacity(0.9))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(maxWidth: prominent ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(prominent ? Color.white : Color.white.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

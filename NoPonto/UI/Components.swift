import SwiftUI

enum TransitStyle {
    static let navy = Color(red: 0.07, green: 0.17, blue: 0.30)
    static let teal = Color(red: 0.00, green: 0.48, blue: 0.48)
    static let blue = Color(red: 0.12, green: 0.39, blue: 0.82)
    static func routeColor(_ route: TransitRoute) -> Color {
        let palette = ["007A7A", "275FC6", "7852B0", "B35B13", "A83D79", "256D91"]
        let hash = route.id.utf8.reduce(UInt32(0)) { ($0 &* 31) &+ UInt32($1) }
        return color(palette[Int(hash % UInt32(palette.count))])
    }
    static func color(_ hex: String) -> Color {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard let value = UInt64(clean, radix: 16), clean.count == 6 else { return teal }
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

struct RouteBadge: View {
    let route: TransitRoute
    var compact = false
    var body: some View {
        Text(route.shortName)
            .font(compact ? .caption.bold() : .headline.bold())
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 9 : 12)
            .padding(.vertical, compact ? 5 : 9)
            .background(TransitStyle.routeColor(route), in: RoundedRectangle(cornerRadius: compact ? 8 : 12))
            .accessibilityLabel("\(route.isBRT ? "BRT" : "Linha") \(route.shortName)")
    }
}

struct InfoNote: View {
    let symbol: String
    let text: String
    var tint: Color = TransitStyle.teal
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 20)
            Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct EmptyTransitState: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(TransitStyle.teal)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(30)
    }
}

struct RoundMapButton: View {
    let symbol: String
    let label: String
    var selected = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 20, weight: .semibold))
                .foregroundStyle(selected ? .white : TransitStyle.teal)
                .frame(width: 48, height: 48)
                .background(selected ? AnyShapeStyle(TransitStyle.teal) : AnyShapeStyle(.regularMaterial), in: Circle())
                .overlay(Circle().strokeBorder(.primary.opacity(0.06)))
                .shadow(color: .black.opacity(0.10), radius: 9, y: 3)
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
}

func distanceLabel(_ meters: Double) -> String {
    if meters < 1_000 { return "\(Int(meters.rounded())) m" }
    return String(format: "%.1f km", meters / 1_000)
}

func sourceAgeLabel(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "sem atualização" }
    let age = max(0, Int(now.timeIntervalSince(date)))
    if age < 60 { return "há \(age) s" }
    if age < 3_600 { return "há \(age / 60) min" }
    return date.formatted(date: .abbreviated, time: .shortened)
}

struct CloseSheetButton: View {
    let action: () -> Void
    var body: some View {
        Button("Fechar", systemImage: "xmark", action: action)
            .labelStyle(.iconOnly).accessibilityLabel("Fechar")
    }
}

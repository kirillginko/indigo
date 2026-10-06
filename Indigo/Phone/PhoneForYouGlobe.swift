//
//  PhoneForYouGlobe.swift
//  Indigo
//
//  For You's first screen: the moving field, uncovered, and over it a globe
//  drawn in characters, turning slowly, with IDA's boxes pinned about its
//  surface -- what to explore next, or, before anything has been kept, every
//  station and the archives. A box turns with the globe, fades as it goes
//  round the back, and comes forward as it faces you. Swiped sideways, the
//  globe turns by hand; swiped up, the feed goes on to the suggestions.
//
//  The characters are a lit sphere with its meridians and a little made-up
//  land, worked out a row at a time, twenty times a second: about a
//  thousand characters, two dozen strings, cheap.
//

import SwiftUI

/// One box on the globe.
struct GlobeItem: Identifiable {
    let id: String
    /// What it is or where, in the green box over its name.
    let label: String
    let title: String
    var isOn = false
    let action: () -> Void
}

struct PhoneForYouGlobe: View {
    let items: [GlobeItem]
    let insets: EdgeInsets

    /// How far the globe has been turned by hand, in radians.
    @State private var turned: Double = 0
    @GestureState private var turning: Double = 0

    /// One turn a minute and a bit, on its own.
    private static let turnsPerSecond = 1.0 / 75
    private static let fontSize: CGFloat = 11
    /// SF Mono's advance is 0.6 of its size; its rows are spaced a size apart.
    private static let cellWidth: CGFloat = fontSize * 0.6
    private static let cellHeight: CGFloat = fontSize * 1.05

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let radius = min(size.width * 0.46, (size.height - insets.top - insets.bottom) * 0.3)
            let center = CGPoint(x: size.width / 2, y: insets.top + (size.height - insets.top - insets.bottom) * 0.46)
            ZStack {
                ExploreShaderField(seed: 0, size: size)
                TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                    let spin = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 1 / Self.turnsPerSecond) * Self.turnsPerSecond * 2 * .pi
                    let rotation = spin + turned + turning
                    ZStack {
                        Canvas { canvas, _ in
                            draw(in: &canvas, center: center, radius: radius, rotation: rotation)
                        }
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            pinned(item, index: index, count: items.count,
                                   center: center, radius: radius, rotation: rotation, width: size.width)
                        }
                    }
                }
                VStack {
                    // The wordmark on its moving green, over the page's name.
                    VStack(spacing: 0) {
                        Text("Mineral")
                            .font(Typeface.mono(17, weight: .medium))
                            .tracking(4)
                            .textCase(.uppercase)
                            .foregroundStyle(Chip.ink)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background { MineralSheenSurface() }
                        Chip(text: "For you", tone: .plain, size: 12, uppercase: true)
                    }
                    .padding(.top, insets.top + 12)
                    Spacer()
                    Image(systemName: "chevron.up")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.bottom, insets.bottom + 22)
                        .accessibilityHidden(true)
                }
                .allowsHitTesting(false)
            }
            // Sideways only: up and down still page the feed.
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .updating($turning) { value, state, _ in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        state = Double(value.translation.width / radius)
                    }
                    .onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        turned += Double(value.translation.width / radius)
                    }
            )
        }
    }

    // MARK: The globe

    /// Light from the upper left, a little in front.
    private static let light = (x: -0.45, y: -0.5, z: 0.74)
    /// Dim to bright.
    private static let ramp = Array(" .,:-=+*#%")

    private func draw(in canvas: inout GraphicsContext, center: CGPoint, radius: CGFloat, rotation: Double) {
        let cols = Int((radius * 2 / Self.cellWidth).rounded(.up))
        let rows = Int((radius * 2 / Self.cellHeight).rounded(.up))
        let left = center.x - CGFloat(cols) * Self.cellWidth / 2
        let top = center.y - CGFloat(rows) * Self.cellHeight / 2
        let font = Font.system(size: Self.fontSize, weight: .semibold, design: .monospaced)
        // Black, with a faint light edge so they hold on the field's dark
        // bands as well as its bright ones.
        canvas.addFilter(.shadow(color: .white.opacity(0.35), radius: 1))

        for row in 0..<rows {
            var line = ""
            line.reserveCapacity(cols)
            let y = (top + (CGFloat(row) + 0.5) * Self.cellHeight - center.y) / radius
            for col in 0..<cols {
                let x = (left + (CGFloat(col) + 0.5) * Self.cellWidth - center.x) / radius
                let rr = Double(x * x + y * y)
                guard rr <= 1 else { line.append(" "); continue }
                let z = (1 - rr).squareRoot()
                line.append(Self.character(x: Double(x), y: Double(y), z: z, rotation: rotation))
            }
            canvas.draw(
                Text(line).font(font).foregroundColor(.black.opacity(0.85)),
                at: CGPoint(x: left, y: top + CGFloat(row) * Self.cellHeight),
                anchor: .topLeading
            )
        }
    }

    private static func character(x: Double, y: Double, z: Double, rotation: Double) -> Character {
        let lat = asin(-y)
        let lon = atan2(x, z) - rotation
        // The graticule: every 30 degrees.
        let step = Double.pi / 6
        let nearMeridian = abs(remainder(lon, step)) < 0.035 / max(cos(lat), 0.2)
        let nearParallel = abs(remainder(lat, step)) < 0.04
        // Lit as a ball is.
        let lambert = max(0, x * light.x + y * light.y + z * light.z)
        // A made-up land, so the turning shows.
        let land = sin(lon * 2 + 0.6) * cos(lat * 3) + 0.6 * sin(lon * 5 - lat * 2) + 0.35 * cos(lon * 9 + lat * 4)
        if nearParallel && nearMeridian { return "+" }
        if nearMeridian { return "|" }
        if nearParallel { return "-" }
        let level = land > 0.55 ? 0.35 + lambert * 0.65 : lambert * 0.35
        let index = min(ramp.count - 1, max(0, Int(level * Double(ramp.count))))
        return ramp[index]
    }

    // MARK: The boxes

    /// Spread evenly over the globe (a Fibonacci spiral), kept off the poles,
    /// where boxes would crowd and barely turn.
    private static func place(_ index: Int, of count: Int) -> (lat: Double, lon: Double) {
        let golden = Double.pi * (3 - 5.0.squareRoot())
        let y = 1 - (Double(index) + 0.5) / Double(max(count, 1)) * 2
        return (asin(y * 0.8), Double(index) * golden)
    }

    @ViewBuilder
    private func pinned(_ item: GlobeItem, index: Int, count: Int,
                        center: CGPoint, radius: CGFloat, rotation: Double, width: CGFloat) -> some View {
        let spot = Self.place(index, of: count)
        let lon = spot.lon + rotation
        let x = cos(spot.lat) * sin(lon)
        let y = -sin(spot.lat)
        let z = cos(spot.lat) * cos(lon)
        // Gone round the back below 0.05; full in front from 0.4.
        let facing = min(1, max(0, (z - 0.05) / 0.35))
        Button(action: item.action) {
            VStack(spacing: 0) {
                Chip(text: item.label, tone: .lead, size: 10, uppercase: true)
                Chip(text: item.title, tone: item.isOn ? .sheen : .plain, size: 12)
                    .lineLimit(2)
                    .frame(maxWidth: 150)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(0.82 + 0.26 * z)
        .opacity(facing)
        .allowsHitTesting(facing > 0.6)
        // Kept on screen: a box at the globe's edge is half off it otherwise.
        .position(x: min(max(center.x + CGFloat(x) * radius, 84), width - 84),
                  y: center.y + CGFloat(y) * radius)
        .zIndex(z)
        .accessibilityHidden(facing < 0.6)
        .accessibilityLabel("\(item.title), \(item.label)")
    }
}

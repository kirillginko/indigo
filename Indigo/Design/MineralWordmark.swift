//
//  MineralWordmark.swift
//  Indigo
//
//  The app's name at the top of the sidebar: monospaced caps on a plate of
//  green metal whose light drifts across it (`mineralSheen`).
//
//  It moves only while the window is active and Reduce Motion is off, at 30
//  frames a second; otherwise it holds one frame. Time is wrapped so the
//  shader's float32 clock never grows large enough to stall.
//

import SwiftUI

struct MineralWordmark: View {
    var title = "Mineral"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    @State private var startedAt = Date()

    /// One full cycle of both waves (2π / 0.9 and 2π / 0.5 share 20π), so the
    /// wrap is seamless.
    private static let period: Double = 20 * .pi

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !appearsActive)) { timeline in
            MineralWordmarkFrame(
                title: title,
                time: reduceMotion ? 2 : timeline.date.timeIntervalSince(startedAt).truncatingRemainder(dividingBy: Self.period))
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

/// One moment of the wordmark, `time` seconds into the cycle.
struct MineralWordmarkFrame: View {
    let title: String
    let time: Double

    var body: some View {
        Text(title)
            .microLabel(2.4, size: 11)
            .foregroundStyle(Color(red: 0.06, green: 0.11, blue: 0.07))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(.white)
                        .colorEffect(ShaderLibrary.mineralSheen(.float2(proxy.size), .float(time)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

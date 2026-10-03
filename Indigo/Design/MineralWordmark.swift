//
//  MineralWordmark.swift
//  Indigo
//
//  The app's name at the top of the sidebar: monospaced caps on a plate of
//  green metal whose light drifts across it (`mineralSheen`).
//
//  It moves at 30 frames a second unless Reduce Motion is on, in a background
//  window too; macOS stops drawing a window nobody can see. Time is wrapped so
//  the shader's float32 clock never grows large enough to stall.
//

import SwiftUI

struct MineralWordmark: View {
    var title = "Mineral"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()

    /// When all three of the shader's waves are back where they started: its
    /// rates are 0.9, 0.35 and 0.5 radians a second, and 0.9t, 0.35t and 0.5t
    /// are all whole turns first at t = 40π. Wrapping anywhere sooner jumps.
    static let period: Double = 40 * .pi

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
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

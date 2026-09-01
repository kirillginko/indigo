//
//  LoadingVeil.swift
//  Indigo
//
//  What a page looks like while it is still being read.
//
//  The alternatives were both tried and both wrong. A grey block reads as a
//  picture that failed rather than one that has not arrived; an empty frame
//  reads as a page that gave up. And several separate spinners — a bar here,
//  a shimmer there — say "three things are happening" when one thing is.
//
//  So there is one treatment, applied to the whole page: what is there is
//  softened and breathes, slowly, and sharpens as it settles. Motion is what
//  distinguishes "coming" from "broken", and doing it once, over everything,
//  keeps the page one object rather than a set of parts in different states.
//

import SwiftUI

extension View {
    /// Softens and breathes while `isLoading`, then settles.
    func loadingVeil(_ isLoading: Bool) -> some View {
        modifier(LoadingVeil(isLoading: isLoading))
    }
}

struct LoadingVeil: ViewModifier {
    let isLoading: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One breath, in seconds. Slow on purpose: a fast pulse reads as alarm,
    /// and this is meant to read as patience.
    private let period: Double = 1.8

    func body(content: Content) -> some View {
        if isLoading {
            // Driven by the clock rather than by state, for the same reason
            // `WorkingBar` is: these pages re-render whenever enrichment
            // writes, and a `repeatForever` animation restarts from nothing
            // on every re-render — so it sits still and reads as stuck.
            TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { context in
                let phase = reduceMotion
                    ? 0.5
                    : Self.breath(context.date.timeIntervalSinceReferenceDate, over: period)
                content
                    .blur(radius: 2.5 + phase * 1.5)
                    .opacity(0.45 + phase * 0.2)
                    .saturation(0.6)
            }
            .transaction { $0.animation = nil }
        } else {
            content
        }
    }

    /// Nought to one and back, smoothly, so there is no jump at the seam.
    private static func breath(_ time: TimeInterval, over period: Double) -> Double {
        let turn = (time.truncatingRemainder(dividingBy: period) / period) * 2 * .pi
        return (1 - cos(turn)) / 2
    }
}

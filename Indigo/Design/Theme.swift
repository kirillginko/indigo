//
//  Theme.swift
//  Indigo
//
//  The visual language: monochrome paper/ink, hairline rules, square corners,
//  uppercase monospaced labels. Inspired by NTS Radio's editorial grid.
//

import CoreText
import SwiftUI

// MARK: - Palette

/// Colours live in the asset catalog (Assets.xcassets/Palette) rather than in
/// code. Asset colours resolve against the view's appearance on the very first
/// render — NSColor dynamic providers can be sampled before the window adopts
/// the system appearance, which shows up as a light-mode flash on launch.
enum Palette {
    private static func named(_ name: String) -> Color {
        Color("Palette/\(name)", bundle: .main)
    }

    /// Page background.
    static let paper = named("Paper")
    /// Slightly recessed background for chrome (sidebar, player bar).
    static let paperChrome = named("PaperChrome")
    /// Primary foreground.
    static let ink = named("Ink")
    /// Secondary foreground for metadata.
    static let inkMuted = named("InkMuted")
    /// Tertiary foreground for timestamps and hints.
    static let inkFaint = named("InkFaint")
    /// Divider between rows.
    static let rule = named("Rule")
    /// Strong border around boxes and buttons.
    static let outline = named("Outline")
    /// Hover / selection wash.
    static let wash = named("Wash")
    /// Sparing accent.
    static let accent = named("Accent")
    /// On-air red.
    static let live = named("Live")
    /// Placeholder fill for missing artwork.
    static let placeholder = named("Placeholder")

    /// Inverted selection block (sidebar current route, primary buttons).
    static let inverse = ink
    static let inverseInk = paper
}

// MARK: - Type

/// Nimbus Sans (URW's Helvetica) is the app's sans. It ships in the bundle
/// rather than being installed, so Core Text has to be handed the files before
/// `Font.custom` can find them by name.
enum Typeface {
    private enum Face {
        static let regular = "NimbusSanL-Regu"
        static let bold = "NimbusSanL-Bold"
        static let condensed = "NimbusSanL-ReguCond"
        static let boldCondensed = "NimbusSanL-BoldCond"
    }

    /// Uppercase monospaced label, wide tracking. The workhorse of the UI
    /// chrome, and deliberately still the system mono — it is the counterpoint
    /// the rest of the type is set against.
    static func micro(_ size: CGFloat = 9.5) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }

    static func mono(_ size: CGFloat = 11, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Nimbus sets larger on the page than the system sans at the same point
    /// size, and heavier as it grows. Rather than re-tune every call site, the
    /// sizes the layout asks for are trimmed here — more at display sizes,
    /// where the extra weight shows most.
    private static let bodyScale: CGFloat = 0.92
    private static let displayScale: CGFloat = 0.84

    /// Nimbus ships two weights, so anything from semibold up is bold and
    /// everything else is regular. `fixedSize` because the layout is a fixed
    /// grid of hairlines — type that grows would break the rules it sits on.
    static func body(_ size: CGFloat = 12.5, weight: Font.Weight = .regular) -> Font {
        .custom(isBold(weight) ? Face.bold : Face.regular, fixedSize: size * bodyScale)
    }

    static func display(_ size: CGFloat = 34) -> Font {
        .custom(Face.bold, fixedSize: size * displayScale)
    }

    /// The condensed cut, for chrome set tight and uppercase.
    static func banner(_ size: CGFloat = 12, weight: Font.Weight = .bold) -> Font {
        .custom(isBold(weight) ? Face.boldCondensed : Face.condensed, fixedSize: size * bodyScale)
    }

    private static func isBold(_ weight: Font.Weight) -> Bool {
        switch weight {
        case .semibold, .bold, .heavy, .black: true
        default: false
        }
    }

    /// Hands every bundled face to Core Text. Called once at launch, before
    /// anything draws. Re-registering an already-registered file is an error
    /// Core Text reports and nothing here needs to act on — and a face that
    /// fails to register simply falls back to the system sans rather than
    /// taking the window down.
    static func registerBundledFonts() {
        let faces = [Face.regular, Face.bold, Face.condensed, Face.boldCondensed]
        let urls = faces.compactMap {
            Bundle.main.url(forResource: $0, withExtension: "ttf")
        }
        guard !urls.isEmpty else { return }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, false) { _, _ in false }
    }
}

// MARK: - Metrics

enum Metrics {
    static let sidebarWidth: CGFloat = 212
    static let playerBarHeight: CGFloat = 68
    static let gutter: CGFloat = 22
    static let rowHeight: CGFloat = 30
    static let hairline: CGFloat = 1.5
    /// Space reserved for the floating traffic lights when the title bar is hidden.
    static let titleBarInset: CGFloat = 30
}

// MARK: - Text helpers

extension View {
    /// Uppercase, tracked, monospaced — the NTS "system label" treatment.
    func microLabel(_ tracking: CGFloat = 1.3, size: CGFloat = 9.5) -> some View {
        self.font(Typeface.micro(size))
            .textCase(.uppercase)
            .tracking(tracking)
    }
}

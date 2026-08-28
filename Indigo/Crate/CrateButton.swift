//
//  CrateButton.swift
//  Indigo
//
//  [ + CRATE ] → [ ✓ CRATED ]. One press, no modal, no account. It flips in
//  place so the listener never loses their spot to a sheet.
//

import SwiftUI

struct CrateButton: View {
    let isCrated: Bool
    var large = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: isCrated ? "checkmark" : "plus")
                    .font(.system(size: large ? 10 : 8.5, weight: .bold))
                Text(isCrated ? "Crated" : "Crate")
                    .microLabel(1.4, size: large ? 11 : 9.5)
            }
            .foregroundStyle(isCrated ? Palette.inverseInk : Palette.ink)
            .padding(.horizontal, large ? 18 : 11)
            .padding(.vertical, large ? 11 : 7)
            .background(isCrated ? Palette.inverse : (isHovering ? Palette.wash : Color.clear))
            .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isCrated)
        .accessibilityLabel(isCrated ? "Remove from crate" : "Add to crate")
    }
}

/// Compact square variant for the player bar, where there is no room for a
/// word next to the transport.
struct CrateGlyphButton: View {
    let isCrated: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isCrated ? "checkmark.square.fill" : "plus.square")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(isCrated ? Palette.ink : (isHovering ? Palette.ink : Palette.inkMuted))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isCrated ? "Remove from crate" : "Add to crate")
        .accessibilityLabel(isCrated ? "Remove from crate" : "Add to crate")
    }
}

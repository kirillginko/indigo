//
//  RootView.swift
//  Indigo
//
//  Fixed sidebar, content column, persistent player bar. The bar spans the
//  full width so the transport never moves when you change section.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The phone layout on a phone-width screen, the sidebar everywhere else --
/// including an iPad, unless split view narrows it to a phone's width.
struct AdaptiveRootView: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        #if os(iOS)
        if sizeClass == .compact || UIDevice.current.userInterfaceIdiom == .phone {
            PhoneRootView()
        } else {
            RootView()
        }
        #else
        RootView()
        #endif
    }
}

struct RootView: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: Metrics.sidebarWidth)
                VRule(color: Palette.outline)
                PageContent()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)

            Rule(color: Palette.outline)
            PlayerBarView()
                .frame(height: Metrics.playerBarHeight)
        }
        .modifier(RootChrome(bottomInset: Metrics.playerBarHeight))
        .ignoresSafeArea(.container, edges: .top)
    }
}

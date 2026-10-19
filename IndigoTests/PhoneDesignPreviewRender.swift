#if os(iOS)
import XCTest
import SwiftUI
import UIKit
@testable import Indigo

/// On-demand visual previews of the actual phone views. Run explicitly when
/// reviewing this design; the environment keeps routine test runs lightweight.
@MainActor
final class PhoneDesignPreviewRender: XCTestCase {
    func testRenderPhoneDesign() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_PHONE_DESIGN_PREVIEW"] == "1")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mineral-phone-preview")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("MINERAL_PREVIEW_DIRECTORY=\(directory.path)")
        let player = PlaybackCoordinator()
        let insets = EdgeInsets(top: 59, leading: 0, bottom: 112, trailing: 0)
        let items: [GlobeItem] = [
            .init(id: "archives", label: "", title: "Digital Archives", action: {}),
            .init(id: "mark", label: "Artist", title: "Mark Broom", action: {}),
            .init(id: "jill", label: "Artist", title: "Jill Scott", action: {}),
            .init(id: "show", label: "Show", title: "100 Elements w/ YL", action: {}),
            .init(id: "label", label: "Label", title: "A-TON", action: {}),
            .init(id: "mum", label: "Artist", title: "Mum & Dad", action: {})
        ]
        func shell(_ view: some View, tab: PhoneTab = .forYou) -> some View {
            view
                .overlay(alignment: .bottom) {
                    PhoneTabBar(selected: tab, searching: false, select: { _ in }, search: {})
                        .padding(.horizontal, 14).padding(.bottom, 24)
                }
                .frame(width: 393, height: 852)
                .environment(player)
                .environment(\.isPhoneLayout, true)
                .environment(\.colorScheme, .dark)
                .ignoresSafeArea()
        }
        func render(_ view: some View, name: String) async throws {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            let host = UIHostingController(rootView: view)
            host.overrideUserInterfaceStyle = .dark
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .seconds(2))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)

        }
        try await render(shell(PhoneForYouGlobe(items: items, insets: insets)), name: "mineral-globe")
        let cards: [(String, PhoneForYouSlide.Card)] = [
            ("artist", .init(picture: nil, kind: "Artist", title: "Jill Scott", subtitle: nil,
                             reason: "Both release on Warner Bros. Records", via: "Prefuse 73", heading: "Toward Soul",
                             button: "DIG IN", icon: "arrow.down.right")),
            ("radio-track", .init(picture: nil, kind: "In a radio show", title: "Burial", subtitle: "Near Dark",
                                  reason: "Played next to Aphex Twin in 3 radio episodes", via: nil, heading: "Close to home",
                                  button: "HEAR IN RADIO SHOW", icon: "dot.radiowaves.left.and.right")),
            ("record", .init(picture: nil, kind: "Record", title: "Untrue", subtitle: "Burial · 2007",
                             reason: "Like records in your crate · Dubstep, Ambient", via: nil, heading: "Toward Ambient",
                             button: "OPEN RECORD", icon: "arrow.down.right"))
        ]
        for (name, card) in cards {
            try await render(shell(PhoneForYouSlide(card: card, insets: insets, open: {})), name: "mineral-\(name)")
        }
    }
}
#endif

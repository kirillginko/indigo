import XCTest
@testable import Indigo

final class PhoneSlideArtworkSizingTests: XCTestCase {
    private let viewport = CGSize(width: 393, height: 852)

    func testSmallPortraitCannotFillARetinaSlide() {
        let pixels = CGSize(width: 600, height: 900)
        XCTAssertFalse(PhoneSlideArtworkSizing.fillsViewport(imagePixels: pixels, viewport: viewport, scale: 3))
        XCTAssertEqual(PhoneSlideArtworkSizing.containedSide(viewport: viewport), 200)
    }

    func testThumbnailAndUnknownResolutionCannotBecomeFullScreen() {
        XCTAssertFalse(PhoneSlideArtworkSizing.fillsViewport(imagePixels: nil, viewport: viewport, scale: 3))
        let thumb = CGSize(width: 150, height: 150)
        XCTAssertFalse(PhoneSlideArtworkSizing.fillsViewport(imagePixels: thumb, viewport: viewport, scale: 3))
        XCTAssertEqual(PhoneSlideArtworkSizing.containedSide(viewport: viewport), 200)
    }

    func testContainedLayoutStaysUniformAndFitsSmallViewports() {
        XCTAssertEqual(PhoneSlideArtworkSizing.containedSide(viewport: viewport), 200)
        XCTAssertEqual(PhoneSlideArtworkSizing.containedSide(viewport: CGSize(width: 430, height: 932)), 200)
        XCTAssertEqual(PhoneSlideArtworkSizing.containedSide(viewport: CGSize(width: 280, height: 600)), 168, accuracy: 0.001)
        XCTAssertEqual(PhoneSlideArtworkSizing.containedSide(viewport: .zero), 0)
    }

    func testBothDimensionsMustCoverTheViewport() {
        XCTAssertFalse(PhoneSlideArtworkSizing.fillsViewport(imagePixels: CGSize(width: 3000, height: 1000), viewport: viewport, scale: 3))
        XCTAssertTrue(PhoneSlideArtworkSizing.fillsViewport(imagePixels: CGSize(width: 2048, height: 3072), viewport: viewport, scale: 3))
    }

    func testHighResolutionSquareCanFillTheSlide() {
        XCTAssertTrue(PhoneSlideArtworkSizing.fillsViewport(imagePixels: CGSize(width: 3000, height: 3000), viewport: viewport, scale: 3))
    }
}

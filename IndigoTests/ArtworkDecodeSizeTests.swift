//
//  ArtworkDecodeSizeTests.swift
//  IndigoTests
//
//  Remote pictures are decoded at the size they are drawn, not the size they
//  were published at. Stations publish camera originals, and For You drew
//  Kiosk's 3024x2016 show photos in 42-point cards: ~25 MB of pixels each for
//  84 on screen.
//

import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Indigo

final class ArtworkDecodeSizeTests: XCTestCase {
    /// A JPEG of the given size, as a station would serve it.
    private func picture(_ width: Int, _ height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func pixels(_ image: PlatformImage) -> (Int, Int) {
        var rect = CGRect(origin: .zero, size: image.size)
        let bitmap = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        return (bitmap?.width ?? 0, bitmap?.height ?? 0)
    }

    /// The case that was measured: an 84-pixel card holding a camera photo.
    func testACardDecodesACameraPhotoAtCardSize() throws {
        let step = RemoteArtworkStore.step(for: 84)
        XCTAssertEqual(step, 128)
        let image = try XCTUnwrap(RemoteArtworkStore.decode(try picture(3024, 2016), step: step))
        let (width, height) = pixels(image)
        // Short edge covers the step, so the square card it fills stays sharp.
        XCTAssertGreaterThanOrEqual(min(width, height), 128)
        XCTAssertLessThanOrEqual(max(width, height), 200)
        XCTAssertLessThan(width * height * 4, 150_000, "was 24 MB decoded whole")
    }

    func testASmallPictureIsNeverEnlarged() throws {
        let image = try XCTUnwrap(RemoteArtworkStore.decode(try picture(150, 150), step: 512))
        XCTAssertEqual(pixels(image).0, 150)
    }

    /// A panorama cannot use its shape to ask for a decode as large as the
    /// ones this replaced.
    func testAPanoramaIsCappedAtThreeToOne() throws {
        let image = try XCTUnwrap(RemoteArtworkStore.decode(try picture(8000, 1000), step: 256))
        XCTAssertLessThanOrEqual(pixels(image).0, 768)
    }

    /// No size given is the largest step, and nothing is decoded past it --
    /// the 8373-pixel covers in the cache included.
    func testNoSizeIsTheLargestStep() {
        XCTAssertEqual(RemoteArtworkStore.step(for: nil), 2048)
        XCTAssertEqual(RemoteArtworkStore.step(for: 9000), 2048)
        XCTAssertEqual(RemoteArtworkStore.step(for: 300), 512)
    }
}

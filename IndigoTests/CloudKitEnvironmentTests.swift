//
//  CloudKitEnvironmentTests.swift
//  IndigoTests
//
//  One store, one CloudKit environment: a Debug build never opens the store a
//  Production build mirrors.
//

import XCTest
@testable import Indigo

final class CloudKitEnvironmentTests: XCTestCase {
    func testProductionKeepsTheStoresEveryInstallAlreadyHas() {
        XCTAssertEqual(StoreLayout.forEnvironment(.production), StoreLayout.standard)
    }

    func testDevelopmentHasAFolderOfItsOwn() {
        let development = StoreLayout.forEnvironment(.development)
        XCTAssertEqual(development.directory.deletingLastPathComponent().standardizedFileURL,
                       StoreLayout.standard.directory.standardizedFileURL)
        XCTAssertEqual(development.directory.lastPathComponent, "Development")
        XCTAssertNotEqual(development.userData, StoreLayout.standard.userData)
        XCTAssertNotEqual(development.legacy, StoreLayout.standard.legacy)
    }

    /// The test host is a Debug build, signed for development.
    func testADebugBuildOpensTheDevelopmentStores() {
        XCTAssertEqual(CloudKitEnvironment.current, .development)
        XCTAssertEqual(Persistence.layout, StoreLayout.forEnvironment(.development))
    }
}

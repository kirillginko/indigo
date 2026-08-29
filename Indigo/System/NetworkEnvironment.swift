//
//  NetworkEnvironment.swift
//  Indigo
//
//  Shared URLSession configuration for every network provider.
//

import Foundation

nonisolated enum NetworkEnvironment {
    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "Indigo/\(version) (macOS; +https://github.com/kirillginko/indigo)"
    }()

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        configuration.requestCachePolicy = .reloadRevalidatingCacheData
        configuration.urlCache = URLCache(
            memoryCapacity: 8 * 1024 * 1024,
            diskCapacity: 64 * 1024 * 1024,
            diskPath: "indigo-network"
        )
        return URLSession(configuration: configuration)
    }()

    /// Catalogue lookups are optional enrichment. Fail quickly enough that a
    /// slow public endpoint never holds a detail page hostage; the persisted
    /// cache and background retry are more useful than a long foreground wait.
    static let metadataSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(
            memoryCapacity: 8 * 1024 * 1024,
            diskCapacity: 64 * 1024 * 1024,
            diskPath: "indigo-metadata"
        )
        return URLSession(configuration: configuration)
    }()
}

//
//  HTTPClient.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal transport the quote providers use to fetch a URL.
///
/// Abstracting the network behind a protocol lets tests feed captured JSON to a
/// provider and assert its parsing, without hitting live endpoints.
public protocol HTTPFetching: Sendable {
    /// Performs `request` and returns the response body, throwing
    /// ``QuoteError/httpStatus(_:)`` on a non-2xx status.
    func data(for request: URLRequest) async throws -> Data
}

/// The production transport, backed by `URLSession`.
public struct URLSessionHTTPClient: HTTPFetching {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw QuoteError.httpStatus(http.statusCode)
        }
        return data
    }
}

extension HTTPFetching {
    /// Convenience: GET `url` with optional headers.
    func get(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return try await data(for: request)
    }
}

/// A browser-like User-Agent; Yahoo's public endpoints reject the default
/// `URLSession` agent with 429/401.
enum HTTPDefaults {
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"
}

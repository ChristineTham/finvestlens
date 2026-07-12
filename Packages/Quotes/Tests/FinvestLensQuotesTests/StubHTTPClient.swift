//
//  StubHTTPClient.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
@testable import FinvestLensQuotes

/// A transport that returns a canned body per matched URL substring, and
/// records the requests it saw so tests can assert URL construction.
final class StubHTTPClient: HTTPFetching, @unchecked Sendable {
    struct Response { let data: Data; let error: Error? }
    private var routes: [(match: String, response: Response)] = []
    private(set) var requestedURLs: [URL] = []

    /// Route requests whose URL contains `match` to `body`.
    func on(_ match: String, body: String) {
        routes.append((match, Response(data: Data(body.utf8), error: nil)))
    }

    func onError(_ match: String, _ error: Error) {
        routes.append((match, Response(data: Data(), error: error)))
    }

    func data(for request: URLRequest) async throws -> Data {
        let url = request.url!
        requestedURLs.append(url)
        let string = url.absoluteString
        guard let route = routes.first(where: { string.contains($0.match) }) else {
            throw QuoteError.noData
        }
        if let error = route.response.error { throw error }
        return route.response.data
    }
}

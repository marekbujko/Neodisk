//
//  TokenBroker.swift
//  Neodisk
//
//  Vends a valid access token for one connected account. Returns the stored
//  token while it still has comfortable life left, otherwise refreshes it
//  through the OAuthAuthorizer and persists the result. Concurrent callers
//  that arrive during a refresh await the same in-flight request, so a burst
//  of API calls triggers exactly one refresh POST (single-flight). A refresh
//  rejected with `invalid_grant` means the account must be reconnected, which
//  surfaces as CloudScanError.authorizationRequired.
//

import Foundation

actor TokenBroker {
    private let providerID: String
    private let accountID: String
    private let authorizer: OAuthAuthorizer
    private let tokenStore: any TokenStoring
    private let now: @Sendable () -> Date
    /// Refresh a token with less than this much life left rather than risk a
    /// mid-request expiry.
    private let expiryLeeway: TimeInterval

    /// The refresh in progress, if any. Callers await its value so a single
    /// refresh serves everyone waiting.
    private var inFlightRefresh: Task<String, Error>?

    init(
        providerID: String,
        accountID: String,
        authorizer: OAuthAuthorizer,
        tokenStore: any TokenStoring,
        expiryLeeway: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.providerID = providerID
        self.accountID = accountID
        self.authorizer = authorizer
        self.tokenStore = tokenStore
        self.expiryLeeway = expiryLeeway
        self.now = now
    }

    /// A usable access token: the cached one when it has more than the leeway
    /// left, otherwise a freshly refreshed one.
    func validToken() async throws -> String {
        let credentials = try loadCredentials()
        if let accessToken = credentials.accessToken,
           let expiry = credentials.accessTokenExpiry,
           expiry.timeIntervalSince(now()) > expiryLeeway {
            return accessToken
        }
        return try await refresh(current: credentials)
    }

    /// Forces a refresh regardless of the cached token's remaining life — used
    /// after a 401, where the server rejected a token we still believed valid.
    func forceRefresh() async throws -> String {
        try await refresh(current: try loadCredentials())
    }

    // MARK: - Refresh (single-flight)

    private func refresh(current credentials: StoredCredentials) async throws -> String {
        // Join an in-progress refresh instead of starting a second one. The
        // check-and-store below has no suspension point, so two callers can
        // never both find `inFlightRefresh` nil and each start a task.
        if let existing = inFlightRefresh {
            return try await existing.value
        }

        let task = Task<String, Error> { [authorizer, tokenStore, providerID, accountID] in
            do {
                let tokens = try await authorizer.refresh(refreshToken: credentials.refreshToken)
                var updated = credentials
                updated.accessToken = tokens.accessToken
                updated.accessTokenExpiry = tokens.expiryDate
                updated.refreshToken = tokens.refreshToken ?? credentials.refreshToken
                try tokenStore.save(updated, forProviderID: providerID, accountID: accountID)
                return tokens.accessToken
            } catch let OAuthError.httpError(_, error, _) where error == "invalid_grant" {
                throw CloudScanError.authorizationRequired
            }
        }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        return try await task.value
    }

    private func loadCredentials() throws -> StoredCredentials {
        guard let credentials = try tokenStore.load(
            forProviderID: providerID, accountID: accountID
        ) else {
            throw CloudScanError.authorizationRequired
        }
        return credentials
    }
}

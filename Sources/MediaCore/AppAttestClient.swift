import Foundation
import CryptoKit
import DeviceCheck

/// Small App Attest client used by the ratings API. The key identifier is kept in
/// UserDefaults; the private key itself remains managed by Apple's Secure Enclave.
public actor AppAttestClient {
    public static let shared = AppAttestClient()
    private let service = DCAppAttestService.shared
    private let keyIDKey = "mivu.app-attest.key-id"
    private let tokenKey = "mivu.app-attest.session-token"
    private let tokenExpiryKey = "mivu.app-attest.session-expiry"

    public func sessionToken(baseURL: URL) async -> String? {
        if let token = UserDefaults.standard.string(forKey: tokenKey),
           let expiry = UserDefaults.standard.object(forKey: tokenExpiryKey) as? Date,
           expiry > Date().addingTimeInterval(30) { return token }
        guard service.isSupported else { return nil }
        do {
            let keyID = try await ensureKeyID(baseURL: baseURL)
            let challenge = try await challenge(baseURL: baseURL, purpose: "assertion")
            let hash = Data(SHA256.hash(data: challenge.bytes))
            let assertion = try await generateAssertion(keyID: keyID, clientDataHash: hash)
            let request = try JSONEncoder().encode(AssertionRequest(challengeId: challenge.id, keyId: keyID, assertion: assertion.base64EncodedString()))
            let result: TokenResponse = try await post(baseURL.appendingPathComponent("v1/app-attest/assert"), body: request)
            UserDefaults.standard.set(result.token, forKey: tokenKey)
            UserDefaults.standard.set(Date().addingTimeInterval(TimeInterval(result.expiresIn - 30)), forKey: tokenExpiryKey)
            return result.token
        } catch { return nil }
    }

    private func ensureKeyID(baseURL: URL) async throws -> String {
        if let existing = UserDefaults.standard.string(forKey: keyIDKey) { return existing }
        let keyID = try await generateKey()
        let challenge = try await challenge(baseURL: baseURL, purpose: "attestation")
        let hash = Data(SHA256.hash(data: challenge.bytes))
        let attestation = try await attestKey(keyID: keyID, clientDataHash: hash)
        let body = try JSONEncoder().encode(AttestationRequest(challengeId: challenge.id, keyId: keyID, attestation: attestation.base64EncodedString()))
        let _: RegisteredResponse = try await post(baseURL.appendingPathComponent("v1/app-attest/attest"), body: body)
        UserDefaults.standard.set(keyID, forKey: keyIDKey)
        return keyID
    }

    private struct Challenge: Decodable { let challengeId: String; let challenge: String
        var id: String { challengeId }
        var bytes: Data { Data(base64URLEncoded: challenge) ?? Data() }
    }
    private struct AttestationRequest: Encodable { let challengeId: String; let keyId: String; let attestation: String }
    private struct AssertionRequest: Encodable { let challengeId: String; let keyId: String; let assertion: String }
    private struct TokenResponse: Decodable { let token: String; let expiresIn: Int }
    private struct RegisteredResponse: Decodable { let registered: Bool }

    private func challenge(baseURL: URL, purpose: String) async throws -> Challenge {
        try await post(baseURL.appendingPathComponent("v1/app-attest/challenge"), body: try JSONEncoder().encode(["purpose": purpose]))
    }
    private func post<T: Decodable>(_ url: URL, body: Data) async throws -> T {
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func generateKey() async throws -> String { try await withCheckedThrowingContinuation { service.generateKey { key, error in if let error { $0.resume(throwing: error) } else if let key { $0.resume(returning: key) } else { $0.resume(throwing: URLError(.cannotCreateFile)) } } } }
    private func attestKey(keyID: String, clientDataHash: Data) async throws -> Data { try await withCheckedThrowingContinuation { service.attestKey(keyID, clientDataHash: clientDataHash) { data, error in if let error { $0.resume(throwing: error) } else if let data { $0.resume(returning: data) } else { $0.resume(throwing: URLError(.cannotDecodeContentData)) } } } }
    private func generateAssertion(keyID: String, clientDataHash: Data) async throws -> Data { try await withCheckedThrowingContinuation { service.generateAssertion(keyID, clientDataHash: clientDataHash) { data, error in if let error { $0.resume(throwing: error) } else if let data { $0.resume(returning: data) } else { $0.resume(throwing: URLError(.cannotDecodeContentData)) } } } }
}

private extension Data {
    init?(base64URLEncoded value: String) { self.init(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - value.count % 4) % 4)) }
}

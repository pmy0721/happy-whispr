import Foundation
import Security
import Combine
import LocalAuthentication

// MARK: - Keychain Service

final class KeychainService {
    private static let serviceName = "com.happywhispr.api"
    private static let accountName = "openrouter-api-key"

    @discardableResult
    static func saveApiKey(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }

        // Delete existing key first
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: serviceName,
            kSecAttrAccount: accountName,
        ] as CFDictionary)

        // Add new key
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: serviceName,
            kSecAttrAccount: accountName,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked,
        ] as CFDictionary, nil)

        return status == errSecSuccess
    }

    static func getApiKey() -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: serviceName,
            kSecAttrAccount: accountName,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8)
        else { return nil }

        return key
    }

    static func hasApiKey() -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true

        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: serviceName,
            kSecAttrAccount: accountName,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: context,
        ] as CFDictionary, nil)

        return status == errSecSuccess
    }

    static func deleteApiKey() {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: serviceName,
            kSecAttrAccount: accountName,
        ] as CFDictionary)
    }
}

// MARK: - STT Service

final class STTService: ObservableObject {

    @Published var transcript: String = ""
    @Published var isLoading: Bool = false

    private let baseURL = "https://openrouter.ai/api/v1/audio/transcriptions"

    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5.0
        config.timeoutIntervalForResource = 10.0
        return URLSession(configuration: config)
    }()

    // MARK: - Transcribe

    func transcribe(audioData wavData: Data, model: String, language: String) async throws -> String {
        try await transcribe(audioData: wavData, model: model, language: language, retryCount: 0)
    }

    private func transcribe(audioData wavData: Data, model: String, language: String, retryCount: Int) async throws -> String {
        guard let apiKey = KeychainService.getApiKey(), !apiKey.isEmpty else {
            throw AppError.apiKeyNotSet
        }

        isLoading = true
        defer { isLoading = false }

        let base64Audio = wavData.base64EncodedString()

        var requestBody: [String: Any] = [
            "model": model,
            "input_audio": [
                "data": base64Audio,
                "format": "wav"
            ]
        ]

        if language != "auto" {
            requestBody["language"] = language
        }

        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        do {
            let (data, response) = try await urlSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AppError.transcriptionFailed("Invalid response")
            }

            switch httpResponse.statusCode {
            case 200:
                return try parseTranscriptionResponse(data: data)
            case 401:
                throw AppError.apiKeyInvalid
            case 429:
                guard retryCount == 0 else {
                    throw AppError.transcriptionFailed("Rate limited (429)")
                }
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return try await transcribe(
                    audioData: wavData,
                    model: model,
                    language: language,
                    retryCount: retryCount + 1
                )
            default:
                let body = String(data: data, encoding: .utf8) ?? "unknown"
                throw AppError.transcriptionFailed("HTTP \(httpResponse.statusCode): \(body)")
            }
        } catch let error as AppError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw AppError.transcriptionTimeout
        } catch {
            throw AppError.transcriptionFailed(error.localizedDescription)
        }
    }

    private func parseTranscriptionResponse(data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.transcriptionFailed("Invalid JSON response")
        }

        guard let text = json["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

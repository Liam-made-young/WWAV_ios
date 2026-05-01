import Foundation
import Security

/// Holds the JWT for `mi-wwav.com` and the remote user. Persisted in keychain.
@MainActor
final class AuthManager: ObservableObject {
    @Published var token: String?
    @Published var user: RemoteUser?
    @Published var isLoading: Bool = false
    @Published var error: String?

    var isLoggedIn: Bool { token != nil && user != nil }

    private let keychainKey = "com.wwav.token"

    init() {
        token = loadFromKeychain()
    }

    /// Re-fetch the user after a fresh launch using the saved token.
    func restoreSession() async {
        guard let t = token else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            user = try await API.client.me(token: t)
        } catch {
            // Token expired or invalid — clear it.
            token = nil
            user = nil
            deleteFromKeychain()
        }
    }

    func login(email: String, password: String) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let resp = try await API.client.login(email: email, password: password)
            token = resp.token
            user = resp.user
            saveToKeychain(resp.token)
        } catch let e as APIError {
            self.error = e.errorDescription
        } catch {
            self.error = "Connection failed"
        }
    }

    func logout() {
        token = nil
        user = nil
        deleteFromKeychain()
    }

    // MARK: – Keychain

    private func saveToKeychain(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainKey,
            kSecValueData as String: data,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainKey,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

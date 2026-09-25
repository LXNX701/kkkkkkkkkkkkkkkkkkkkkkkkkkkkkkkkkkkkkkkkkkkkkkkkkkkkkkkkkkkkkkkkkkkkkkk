import Foundation
import SwiftUI
import UIKit
import Security
import CryptoKit

enum ProtectedAction: String {
    case tabNavigation = "tab-navigation"
    case gameSelection = "game-selection"
    case patchToggle = "patch-toggle"
    case patchApply = "patch-apply"
    case patchRestore = "patch-restore"
}

struct ActionPermit {
    let action: String
    let issuedAt: TimeInterval
    let nonce: String
    let signature: String
}

enum AuthGateError: LocalizedError {
    case blocked

    var errorDescription: String? {
        "Autenticação obrigatória. Ação bloqueada."
    }
}

private final class AuthRuntimeGate {
    static let shared = AuthRuntimeGate()

    private let lock = NSLock()
    private var sessionSecret: String?
    private var serverExpiry: Date?

    private init() {}

    func open(key: String, deviceToken: String, expiresAt: Date?) {
        let processNonce = UUID().uuidString + UUID().uuidString
        let material = [
            key,
            deviceToken,
            processNonce,
            "MOONX7-LICENSE-RUNTIME-V1"
        ].joined(separator: "|")

        lock.lock()
        sessionSecret = Self.sha256(material)
        serverExpiry = expiresAt
        lock.unlock()
    }

    func close() {
        lock.lock()
        sessionSecret = nil
        serverExpiry = nil
        lock.unlock()
    }

    func makePermit(for action: ProtectedAction) -> ActionPermit? {
        lock.lock()
        defer { lock.unlock() }

        guard let secret = sessionSecret else { return nil }
        if let serverExpiry, serverExpiry <= Date() { return nil }

        let issuedAt = Date().timeIntervalSince1970
        let nonce = UUID().uuidString
        let signature = Self.sha256("\(secret)|\(action.rawValue)|\(issuedAt)|\(nonce)")
        return ActionPermit(action: action.rawValue, issuedAt: issuedAt, nonce: nonce, signature: signature)
    }

    func validate(_ permit: ActionPermit, for action: ProtectedAction) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let secret = sessionSecret,
              permit.action == action.rawValue else { return false }

        if let serverExpiry, serverExpiry <= Date() { return false }

        let age = Date().timeIntervalSince1970 - permit.issuedAt
        guard age >= -2, age <= 15 else { return false }

        let expected = Self.sha256("\(secret)|\(action.rawValue)|\(permit.issuedAt)|\(permit.nonce)")
        return Self.constantTimeEqual(expected, permit.signature)
    }

    func isOpen() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard sessionSecret != nil else { return false }
        if let serverExpiry, serverExpiry <= Date() { return false }
        return true
    }

    private static func sha256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in a.indices { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}

final class AuthProtection: ObservableObject {
    static let shared = AuthProtection()

    enum State: Equatable {
        case checking
        case waitingForAuth
        case authorized
        case denied(String)
    }

    @Published private(set) var state: State = .checking
    @Published private(set) var licenseKey: String?
    @Published private(set) var expiresAt: Date?
    @Published private(set) var lastValidation: Date?

    private var pollTimer: Timer?
    private var presenceTimer: Timer?
    private var refreshInProgress = false

    private init() {}

    var isAuthorized: Bool {
        if case .authorized = state { return true }
        return false
    }

    var displayedKey: String {
        licenseKey ?? "–"
    }

    var expirationDisplay: String {
        guard let expiresAt else {
            return isAuthorized ? "Sem expiração" : "–"
        }

        let seconds = Int(expiresAt.timeIntervalSinceNow)
        guard seconds > 0 else { return "Expirada" }

        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        if days > 0 { return "\(days)d \(hours)h \(minutes)min" }
        if hours > 0 { return "\(hours)h \(minutes)min" }
        return "\(max(minutes, 1))min"
    }

    var lockMessage: String {
        switch state {
        case .checking:
            return "Verificando autenticação…"
        case .waitingForAuth:
            return "Enter a valid MOONX7 license key to unlock the app."
        case .authorized:
            return ""
        case .denied(let reason):
            return reason
        }
    }

    @MainActor
    @discardableResult
    func loginWithKey(_ rawKey: String) async -> Bool {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            deny("Ingresa una key MOONX7 válida.")
            return false
        }

        guard let deviceToken = KeychainReader.deviceIdentifier() else {
            deny("No se pudo crear la identificación del dispositivo.")
            return false
        }
        do {
            let activation = try await AuthAPI.activate(key: key, deviceToken: deviceToken)
            guard activation.success else {
                deny(activation.message ?? "La key no pudo activarse.")
                return false
            }

            guard KeychainReader.write(
                service: KeychainReader.service,
                account: KeychainReader.keyAccount,
                value: key
            ) else {
                deny("No se pudo guardar la licencia en el Keychain.")
                return false
            }

            let verified = await refresh(forceRemote: true)
            if verified {
                return true
            }

            KeychainReader.delete(service: KeychainReader.service, account: KeychainReader.keyAccount)
            AuthRuntimeGate.shared.close()
            licenseKey = nil
            expiresAt = nil
            return false
        } catch {
            deny("No se pudo conectar con el servidor de licencias MOONX7.")
            return false
        }
    }

    @MainActor
    func logout() {
        KeychainReader.delete(service: KeychainReader.service, account: KeychainReader.keyAccount)
        if let key = licenseKey, let deviceToken = KeychainReader.read(service: KeychainReader.service, account: KeychainReader.deviceTokenAccount) {
            Task { try? await AuthAPI.endPresence(key: key, deviceToken: deviceToken) }
        }
        AuthRuntimeGate.shared.close()
        licenseKey = nil
        expiresAt = nil
        lastValidation = nil
        state = .waitingForAuth
    }

    @MainActor
    func bootstrap() async {
        startPolling()
        _ = await refresh(forceRemote: true)
    }

    @MainActor
    func appBecameActive() async {        _ = await refresh(forceRemote: true)
    }

    @MainActor
    func permit(for action: ProtectedAction) async -> ActionPermit? {
        // IMPORTANT: protected UI actions must never wait for the network.
        // Remote validation already runs at bootstrap, when the app becomes active
        // and from the polling loop. Here we only use the already-open runtime gate,
        // so tabs/switches respond immediately while still failing closed.
        guard isAuthorized,
              let permit = AuthRuntimeGate.shared.makePermit(for: action),
              AuthRuntimeGate.shared.validate(permit, for: action) else {
            return nil
        }

        // Keep the server state fresh without putting latency on the user's tap.
        if lastValidation == nil || Date().timeIntervalSince(lastValidation!) >= 20 {
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await self.refresh(forceRemote: true)
            }
        }

        return permit
    }

    @MainActor
    @discardableResult
    func refresh(forceRemote: Bool) async -> Bool {
        if !forceRemote,
           isAuthorized,
           let lastValidation,
           Date().timeIntervalSince(lastValidation) < 25 {
            return true
        }

        if refreshInProgress { return false }
        refreshInProgress = true
        defer { refreshInProgress = false }
        guard let key = KeychainReader.read(service: KeychainReader.service, account: KeychainReader.keyAccount),
              !key.isEmpty,
              let deviceToken = KeychainReader.read(service: KeychainReader.service, account: KeychainReader.deviceTokenAccount),
              !deviceToken.isEmpty else {
            AuthRuntimeGate.shared.close()
            licenseKey = nil
            expiresAt = nil
            state = .waitingForAuth
            return false
        }

        do {
            let response = try await AuthAPI.check(key: key, deviceToken: deviceToken)
            guard response.status.lowercased() == "active" else {
                deny("Key sem status ativo.")
                return false
            }
            guard response.key == key else {
                deny("Key retornada pela API não corresponde à autenticação local.")
                return false
            }

            let expiration = response.expiresAt.flatMap(AuthAPI.parseDate)
            if let expiration, expiration <= Date() {
                deny("A key expirou.")
                return false
            }

            if response.pausedAt != nil {
                deny("A key está pausada.")
                return false
            }

            licenseKey = key
            expiresAt = expiration
            lastValidation = Date()
            AuthRuntimeGate.shared.open(key: key, deviceToken: deviceToken, expiresAt: expiration)
            state = .authorized
            Task { try? await AuthAPI.reportPresence(key: key, deviceToken: deviceToken, deviceModel: UIDevice.current.model, appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) }
            return true
        } catch {
            deny("Falha ao validar a key na API. Conexão online obrigatória.")
            return false
        }
    }

    @MainActor
    private func deny(_ reason: String) {
        AuthRuntimeGate.shared.close()
        licenseKey = nil
        expiresAt = nil
        state = .denied(reason)
    }

    @MainActor
    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in
                _ = await AuthProtection.shared.refresh(forceRemote: false)
            }
        }
    }

     static func validatePermit(_ permit: ActionPermit, for action: ProtectedAction) -> Bool {
        AuthRuntimeGate.shared.validate(permit, for: action)
    }

    static func runtimeAccessAllowed() -> Bool {
        AuthRuntimeGate.shared.isOpen()
    }

    var stateDescriptionIsDenied: Bool {
        if case .denied = state { return true }
        return false
    }
}

private enum KeychainReader {
    static let service = "com.moonx7.license"
    static let keyAccount = "license-key"
    static let deviceTokenAccount = "device-token"
    static func write(service: String, account: String, value: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func deviceIdentifier() -> String? {
        if let saved = read(service: service, account: deviceTokenAccount), !saved.isEmpty {
            return saved
        }

        let identifier = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        return write(
            service: service,
            account: deviceTokenAccount,
            value: identifier
        ) ? identifier : nil
    }

    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }
}

private enum AuthAPI {
    private static let supabaseURL = URL(string: "https://qgetvnmrhrcagnvpfgmr.supabase.co")!
    // Publishable client key is safe to embed in the app. Never embed service_role.
    private static let publishableKey = "sb_publishable_fyPxGwyJtHFK9gxkYv6FKw_1xi15e_l"

    struct CheckResponse: Decodable {
        let key: String
        let status: String
        let activatedAt: String?
        let expiresAt: String?
        let pausedAt: String?
        let remainingMS: Double?

        enum CodingKeys: String, CodingKey {
            case key
            case status
            case activatedAt = "activated_at"
            case expiresAt = "expires_at"
            case pausedAt = "paused_at"
            case remainingMS = "remaining_ms"
        }
    }

    struct RPCResponse: Decodable {
        let success: Bool
        let status: String?
        let plan: String?
        let durationDays: Int?
        let activatedAt: String?
        let expiresAt: String?
        let message: String?
        let deviceBound: Bool?

        enum CodingKeys: String, CodingKey {
            case success, status, plan, message
            case durationDays = "duration_days"
            case activatedAt = "activated_at"
            case expiresAt = "expires_at"
            case deviceBound = "device_bound"
        }
    }

    static func check(key: String, deviceToken: String) async throws -> CheckResponse {
        let result = try await rpc(
            "verify_license",
            body: ["p_license_key": key, "p_udid": deviceToken],
            response: RPCResponse.self
        )

        guard result.success else {
            throw NSError(
                domain: "MoonX7Auth",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: result.message ?? "License verification failed"]
            )
        }

        return CheckResponse(
            key: key,
            status: result.status ?? "inactive",
            activatedAt: result.activatedAt,
            expiresAt: result.expiresAt,
            pausedAt: nil,
            remainingMS: nil
        )
    }

    static func activate(key: String, deviceToken: String) async throws -> RPCResponse {
        try await rpc(
            "activate_license",
            body: ["p_license_key": key, "p_udid": deviceToken],
            response: RPCResponse.self
        )
    }

    private static func rpc<T: Decodable>(
        _ function: String,
        body: [String: Any],
        response: T.Type
    ) async throws -> T {
        let url = supabaseURL.appendingPathComponent("rest/v1/rpc/\(function)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 12
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Supabase request failed"
            throw NSError(
                domain: "MoonX7Auth",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    static func reportPresence(key: String, deviceToken: String, deviceModel: String?, appVersion: String?) async throws {
        _ = try await rpc("report_app_presence", body: [
            "p_license_key": key,
            "p_udid": deviceToken,
            "p_device_model": deviceModel as Any,
            "p_app_version": appVersion as Any,
            "p_game": "MOONX7"
        ], response: RPCResponse.self)
    }

    static func endPresence(key: String, deviceToken: String) async throws {
        _ = try await rpc("end_app_presence", body: ["p_license_key": key, "p_udid": deviceToken], response: RPCResponse.self)
    }

    static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

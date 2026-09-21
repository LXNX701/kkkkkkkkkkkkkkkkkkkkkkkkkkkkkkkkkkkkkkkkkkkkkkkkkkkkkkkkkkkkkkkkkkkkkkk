import SwiftUI
import Foundation
import UIKit
import Security
import ImageIO
import AVKit

// ============================================================
// MARK: - CONTENT VIEW
// ============================================================

struct ContentView: View {
    @State private var tab = 0
    @AppStorage("external.darkMode") private var darkMode = true

    private var scheme: ColorScheme { darkMode ? .dark : .light }
    private var bg: Color { darkMode ? .black : Color(uiColor: .systemGroupedBackground) }

    @StateObject private var auth = MoonAuthManager()

    var body: some View {
        Group {
            if auth.isChecking {
                ZStack {
                    Color.black.ignoresSafeArea()
                    ProgressView("Verificando acceso…").tint(.white).foregroundStyle(.white)
                }
            } else if auth.isAuthenticated {
                authenticatedView
            } else {
                MoonLoginView(auth: auth)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var authenticatedView: some View {
        ZStack(alignment: .bottom) {
            bg.ignoresSafeArea()

            Group {
                if tab == 0 {
                    ExternalFunctionsView(darkMode: darkMode)
                } else if tab == 1 {
                    PreviewView(darkMode: darkMode)
                } else {
                    ConfigDashboardView(auth: auth, darkMode: $darkMode)
                }
            }
            .padding(.bottom, 72)

            HStack(spacing: 8) {
                BottomItem(icon: "house.fill", title: "Function", selected: tab == 0, darkMode: darkMode) { tab = 0 }
                BottomItem(icon: "play.rectangle.fill", title: "Preview", selected: tab == 1, darkMode: darkMode) { tab = 1 }
                BottomItem(icon: "cube.fill", title: "Config", selected: tab == 2, darkMode: darkMode) { tab = 2 }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 8)

            if auth.isAuthenticated {
                VStack {
                    HStack {
                        Spacer()
                        Button("Salir") { auth.signOut() }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.65))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.white.opacity(0.07), in: Capsule())
                    }
                    .padding(.top, 48)
                    .padding(.horizontal, 18)
                    Spacer()
                }
            }
        }
        .environment(\.colorScheme, scheme)
        .preferredColorScheme(scheme)
    }
}


// ============================================================
// MARK: - MOONX7 LICENSE AUTH

private final class MoonAuthManager: ObservableObject {
    @Published var isAuthenticated = false
    @Published var isChecking = true
    @Published var errorMessage: String?
    @Published private(set) var licenseKey: String?
    @Published private(set) var expiresAt: Date?
    @Published private(set) var plan: String?
    @Published private(set) var durationDays: Int?
    @Published private(set) var activatedAt: Date?

    private let supabaseURL = URL(string: "https://qgetvnmrhrcagnvpfgmr.supabase.co")!
    private let publishableKey = "sb_publishable_fyPxGwyJtHFK9gxkYv6FKw_1xi15e_l"
    private let keyService = "com.moonx7.license"
    private let licenseAccount = "license-key"
    private let deviceAccount = "device-token"

    init() {
        Task { @MainActor in
            await bootstrap()
        }
    }

    @MainActor
    func bootstrap() async {
        isChecking = true
        guard let key = readKeychain(licenseAccount), !key.isEmpty else {
            isAuthenticated = false
            isChecking = false
            return
        }

        do {
            let device = try deviceToken()
            let response = try await rpc(
                "verify_license",
                body: ["p_license_key": key, "p_udid": device]
            )

            guard response.success, response.status == "active" else {
                clearSession()
                isChecking = false
                return
            }

            let expiry = parseDate(response.expiresAt)
            if let expiry, expiry <= Date() {
                clearSession()
                isChecking = false
                return
            }

            licenseKey = key
            expiresAt = expiry
            plan = response.plan
            durationDays = response.durationDays
            activatedAt = parseDate(response.activatedAt)
            isAuthenticated = true
        } catch {
            isAuthenticated = false
            errorMessage = "No se pudo validar la licencia. Revisa tu conexión."
        }

        isChecking = false
    }

    @MainActor
    func signIn(key rawKey: String) {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        guard !key.isEmpty else {
            errorMessage = "Escribe tu key MOONX7."
            return
        }

        errorMessage = nil
        isChecking = true

        Task { @MainActor in
            do {
                let device = try deviceToken()

                let activation = try await rpc(
                    "activate_license",
                    body: ["p_license_key": key, "p_udid": device]
                )

                guard activation.success else {
                    errorMessage = activation.message ?? "La licencia no pudo activarse."
                    isAuthenticated = false
                    isChecking = false
                    return
                }

                let verified = try await rpc(
                    "verify_license",
                    body: ["p_license_key": key, "p_udid": device]
                )

                guard verified.success, verified.status == "active" else {
                    errorMessage = verified.message ?? "La licencia no pudo verificarse."
                    isAuthenticated = false
                    isChecking = false
                    return
                }

                guard writeKeychain(key, account: licenseAccount) else {
                    errorMessage = "No se pudo guardar la licencia en este dispositivo."
                    isAuthenticated = false
                    isChecking = false
                    return
                }

                licenseKey = key
                expiresAt = parseDate(verified.expiresAt)
                plan = verified.plan
                durationDays = verified.durationDays
                activatedAt = parseDate(verified.activatedAt)
                isAuthenticated = true
                isChecking = false
            } catch {
                errorMessage = "No se pudo conectar con el servidor de licencias MOONX7."
                isAuthenticated = false
                isChecking = false
            }
        }
    }

    @MainActor
    func signOut() {
        deleteKeychain(licenseAccount)
        licenseKey = nil
        expiresAt = nil
        plan = nil
        durationDays = nil
        activatedAt = nil
        isAuthenticated = false
        errorMessage = nil
    }

    private struct RPCResponse: Decodable {
        let success: Bool
        let status: String?
        let plan: String?
        let durationDays: Int?
        let activatedAt: String?
        let expiresAt: String?
        let remainingMS: Double?
        let deviceBound: Bool?
        let message: String?

        enum CodingKeys: String, CodingKey {
            case success, status, plan, message
            case durationDays = "duration_days"
            case activatedAt = "activated_at"
            case expiresAt = "expires_at"
            case remainingMS = "remaining_ms"
            case deviceBound = "device_bound"
        }
    }

    private func rpc(_ function: String, body: [String: String]) async throws -> RPCResponse {
        let url = supabaseURL.appendingPathComponent("rest/v1/rpc/\(function)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue(publishableKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "Supabase request failed"
            throw NSError(
                domain: "MoonX7Auth",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }

        return try JSONDecoder().decode(RPCResponse.self, from: data)
    }

    private func deviceToken() throws -> String {
        if let saved = readKeychain(deviceAccount), !saved.isEmpty {
            return saved
        }

        let token = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString

        guard writeKeychain(token, account: deviceAccount) else {
            throw NSError(domain: "MoonX7Auth", code: -2)
        }

        return token
    }

    private func readKeychain(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?

        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private func writeKeychain(_ value: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService,
            kSecAttrAccount as String: account
        ]

        let data = Data(value.utf8)
        let update = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if update == errSecSuccess {
            return true
        }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private func deleteKeychain(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)
    }

    private func clearSession() {
        deleteKeychain(licenseAccount)
        licenseKey = nil
        expiresAt = nil
        plan = nil
        durationDays = nil
        activatedAt = nil
        isAuthenticated = false
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private struct MoonLoginView: View {
    @ObservedObject var auth: MoonAuthManager
    @State private var licenseKey = ""

    private let moon = Color(red: 0.47, green: 0.31, blue: 1.00)
    private let cyan = Color(red: 0.18, green: 0.84, blue: 1.00)
    private let panel = Color(red: 0.055, green: 0.063, blue: 0.11)

    private var canSubmit: Bool {
        !auth.isChecking && !licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var status: (icon: String, text: String, color: Color) {
        if auth.isChecking {
            return ("arrow.triangle.2.circlepath", "Verificando licencia segura…", cyan)
        }

        if let error = auth.errorMessage {
            return ("exclamationmark.triangle.fill", error, .red)
        }

        return ("lock.fill", "Tu key se valida de forma segura.", .white.opacity(0.48))
    }

    var body: some View {
        ZStack {
            Color(red: 0.018, green: 0.024, blue: 0.055)
                .ignoresSafeArea()

            RadialGradient(
                colors: [moon.opacity(0.42), moon.opacity(0.10), .clear],
                center: .top,
                startRadius: 10,
                endRadius: 460
            )
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer(minLength: 72)

                    ZStack {
                        Circle()
                            .fill(moon.opacity(0.20))
                            .frame(width: 108, height: 108)
                            .blur(radius: 16)

                        Image(systemName: "moon.stars.fill")
                            .font(.system(size: 49, weight: .bold))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [cyan, moon],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }

                    AnimatedGIFView(filename: "realm-banner.gif")
                        .frame(height: 86)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(cyan.opacity(0.28), lineWidth: 1)
                        }
                        .shadow(color: moon.opacity(0.20), radius: 18, y: 8)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 18)

                    Text("MOON X7")
                        .font(.system(size: 38, weight: .black, design: .rounded))
                        .tracking(5)
                        .foregroundStyle(.white)
                        .padding(.top, 18)

                    Text("ACCESS CONTROL")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(3.2)
                        .foregroundStyle(cyan.opacity(0.82))
                        .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Acceso privado")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)

                            Text("Introduce tu key para continuar.")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.52))
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("LICENSE KEY")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(1.5)
                                .foregroundStyle(.white.opacity(0.42))

                            HStack(spacing: 12) {
                                Image(systemName: "key.horizontal.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(cyan)

                                TextField("MOONX7-XXXX-XXXX", text: $licenseKey)
                                    .textInputAutocapitalization(.characters)
                                    .autocorrectionDisabled()
                                    .foregroundStyle(.white)
                                    .font(.system(size: 14, weight: .semibold, design: .monospaced))

                                Button {
                                    licenseKey = UIPasteboard.general.string ?? licenseKey
                                } label: {
                                    Text("PEGAR")
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .foregroundStyle(cyan)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .background(cyan.opacity(0.12), in: Capsule())
                                }
                                .accessibilityLabel("Pegar key desde el portapapeles")
                            }
                            .padding(.horizontal, 15)
                            .frame(height: 58)
                            .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 16))
                            .overlay {
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(auth.errorMessage == nil ? .white.opacity(0.10) : .red.opacity(0.72), lineWidth: 1)
                            }
                        }

                        Button {
                            auth.signIn(key: licenseKey)
                        } label: {
                            HStack(spacing: 10) {
                                if auth.isChecking {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "arrow.right")
                                }

                                Text(auth.isChecking ? "VERIFICANDO" : "CONTINUAR")
                            }
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(
                                LinearGradient(
                                    colors: [moon, Color(red: 0.30, green: 0.20, blue: 0.86)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                in: RoundedRectangle(cornerRadius: 16)
                            )
                            .shadow(color: moon.opacity(0.32), radius: 16, y: 8)
                        }
                        .disabled(!canSubmit)
                        .opacity(canSubmit ? 1 : 0.48)

                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: status.icon)
                                .font(.system(size: 12, weight: .semibold))
                            Text(status.text)
                                .font(.system(size: 12, weight: .medium))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(status.color)
                        .animation(.easeInOut(duration: 0.2), value: auth.isChecking)
                        .animation(.easeInOut(duration: 0.2), value: auth.errorMessage)
                    }
                    .padding(24)
                    .background(panel.opacity(0.90), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(.white.opacity(0.10), lineWidth: 1)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 36)

                    Text("MOONX7 • SECURE LICENSE ACCESS")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.32))
                        .padding(.top, 22)
                        .padding(.bottom, 30)
                }
                .frame(maxWidth: .infinity, minHeight: UIScreen.main.bounds.height)
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - PATCH OPTIONS
// ============================================================

private struct PatchOption: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let patchFile: String
    let patchPassword: String
    let manualControls: Bool
    let isTexture: Bool

    init(
        id: String,
        title: String,
        subtitle: String?,
        patchFile: String,
        patchPassword: String,
        manualControls: Bool,
        isTexture: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.patchFile = patchFile
        self.patchPassword = patchPassword
        self.manualControls = manualControls
        self.isTexture = isTexture
    }
}


// ============================================================
// MARK: - PATCH FILE CONFIGURATION
// ============================================================

private enum PatchSlots {

    // FREE FIRE NORMAL - reserved for future patches.
    // Keep this section empty until normal FF resources are added.

    // FREE FIRE MAX - all 10 current options.
    static let ffmx1 = "FFMX MOON CABEZA ATN.3105"
    static let ffmx2 = "FFMX MOON CUELLO ATN.3105"
    static let ffmx3 = "FFMX MOON CUELLO.3105"
    static let ffmx4 = "FFMX MOON DRAG ATN.3105"
    static let ffmx5 = "FFMX MOON DRAG.3105"
    static let ffmx6 = "FFMX MOON MAGIC ATN.3105"
    static let ffmx7 = "FFMX MOON MAGICA.3105"
    static let ffmx8 = "FFMX MOON PECHO ATN.3105"
    static let ffmx9 = "FFMX MOON PECHO.3105"
    static let ffmx10 = "MOON CABEZA.3105"

    static let password = "0"
}


// ============================================================
// MARK: - SHARED THEME
// ============================================================

private enum Theme {
    static let accent = Color(red: 0.95, green: 0.08, blue: 0.16)
    static let accentAlt = Color(red: 0.76, green: 0.03, blue: 0.10)
    static let violet = Color(red: 0.46, green: 0.10, blue: 0.78)
    static let silver = Color(red: 0.90, green: 0.91, blue: 0.95)

    static func dim(_ darkMode: Bool, _ value: Double) -> Color {
        darkMode ? Color.white.opacity(value) : Color.black.opacity(value)
    }
}


// ============================================================
// MARK: - EXTERNAL FUNCTIONS
// ============================================================

private struct ExternalFunctionsView: View {

    let darkMode: Bool

    @State private var game = 1
    @State private var enabled: Set<String> = []

    // --------------------------------------------------------
    // FREE FIRE
    // --------------------------------------------------------

    private let freeFireOptions: [PatchOption] = []

    // --------------------------------------------------------
    // FREE FIRE MAX
    // --------------------------------------------------------

    private let freeFireMaxOptions: [PatchOption] = [
        PatchOption(id: "ffmx-01", title: "MOON CABEZA ATN", subtitle: "FF MAX", patchFile: PatchSlots.ffmx1, patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "ffmx-02", title: "MOON CUELLO ATN", subtitle: "FF MAX", patchFile: PatchSlots.ffmx2, patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "ffmx-03", title: "MOON CUELLO", subtitle: "FF MAX", patchFile: PatchSlots.ffmx3, patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "ffmx-04", title: "MOON DRAG ATN", subtitle: "FF MAX", patchFile: PatchSlots.ffmx4, patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "ffmx-05", title: "MOON DRAG", subtitle: "FF MAX", patchFile: PatchSlots.ffmx5, patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "ffmx-06", title: "MOON MAGIC ATN", subtitle: "FF MAX", patchFile: PatchSlots.ffmx6, patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "ffmx-07", title: "MOON MAGICA", subtitle: "FF MAX", patchFile: PatchSlots.ffmx7, patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "ffmx-08", title: "MOON PECHO ATN", subtitle: "FF MAX", patchFile: PatchSlots.ffmx8, patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "ffmx-09", title: "MOON PECHO", subtitle: "FF MAX", patchFile: PatchSlots.ffmx9, patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "ffmx-10", title: "MOON CABEZA", subtitle: "FF MAX", patchFile: PatchSlots.ffmx10, patchPassword: PatchSlots.password, manualControls: true),

        // Texture options moved into FF MAX.
        PatchOption(id: "ffmx-texture-01", title: "ARM HOLO BORDE AZUL Y ROJO", subtitle: "FF MAX • HOLO", patchFile: "ARM HOLO BORDE AZUL Y ROJO.3105", patchPassword: PatchSlots.password, manualControls: false, isTexture: true),
        PatchOption(id: "ffmx-texture-02", title: "ARM HOLO BORDE RTX", subtitle: "FF MAX • HOLO", patchFile: "ARM HOLO BORDE RTX.3105", patchPassword: PatchSlots.password, manualControls: false, isTexture: true),
        PatchOption(id: "ffmx-texture-03", title: "ARM HOLO BORDE VERDE AMARILLO", subtitle: "FF MAX • HOLO", patchFile: "ARM HOLO BORDE VERDE AMARILLO.3105", patchPassword: PatchSlots.password, manualControls: false, isTexture: true),
        PatchOption(id: "ffmx-texture-04", title: "PJ HOLO MOON VIP", subtitle: "FF MAX • HOLO", patchFile: "PJ HOLO MOON VIP.3105", patchPassword: PatchSlots.password, manualControls: false, isTexture: true),
        PatchOption(id: "ffmx-texture-05", title: "PJ HOLO ROBOT AMARILLO", subtitle: "FF MAX • HOLO", patchFile: "PJ HOLO ROBOT AMARILLO.3105", patchPassword: PatchSlots.password, manualControls: false, isTexture: true),
        PatchOption(id: "ffmx-texture-06", title: "PJ HOLO ROBOT CIAN", subtitle: "FF MAX • HOLO", patchFile: "PJ HOLO ROBOT CIAN.3105", patchPassword: PatchSlots.password, manualControls: false, isTexture: true),
        PatchOption(id: "ffmx-texture-07", title: "PJ HOLO ROBOT ROJO", subtitle: "FF MAX • HOLO", patchFile: "PJ HOLO ROBOT ROJO.3105", patchPassword: PatchSlots.password, manualControls: false, isTexture: true)
    ]

    private var currentOptions: [PatchOption] {
        game == 0 ? freeFireOptions : freeFireMaxOptions
    }

    // --------------------------------------------------------
    // BODY
    // --------------------------------------------------------

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                headerSection
                gameSelectorSection
                currentGameSection
                optionsListSection
                Spacer().frame(height: 90)
            }
            .padding(.horizontal, 20)
        }
    }

    // --------------------------------------------------------
    // SECTIONS
    // --------------------------------------------------------

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Theme.accent.opacity(0.18))
                        .frame(width: 54, height: 54)
                        .blur(radius: 8)
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 27, weight: .black))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Theme.silver, Theme.accent],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("MOON X7")
                        .font(.system(size: 25, weight: .black, design: .rounded))
                        .tracking(2)
                    Text("CONTROL CENTER • UI REDESIGN 1.1")
                        .font(.system(size: 8.5, weight: .black, design: .rounded))
                        .tracking(1.3)
                        .foregroundStyle(Theme.accent)
                }

                Spacer()

                Label("LIVE", systemImage: "circle.fill")
                    .font(.system(size: 8.5, weight: .black, design: .rounded))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.05), in: Capsule())
            }

            ZStack(alignment: .bottomLeading) {
                AnimatedGIFView(filename: "realm-banner.gif")
                    .frame(height: 152)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                LinearGradient(
                    colors: [.clear, .black.opacity(0.82)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("FREE FIRE MAX")
                        .font(.system(size: 23, weight: .black, design: .rounded))
                    Text("17 OPTIONS • 7 HOLO INTEGRATED")
                        .font(.system(size: 9.5, weight: .black, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(.white.opacity(0.62))
                }
                .foregroundStyle(.white)
                .padding(17)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Theme.accent.opacity(0.7), Theme.violet.opacity(0.38), .white.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.2
                    )
            }
            .shadow(color: Theme.accent.opacity(0.18), radius: 22, y: 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 56)
        .padding(.bottom, 20)
    }

    private var gameSelectorSection: some View {
        HStack(spacing: 10) {
            GameButton(
                title: "FREE FIRE",
                subtitle: "NORMAL",
                selected: game == 0,
                darkMode: darkMode
            ) {
                withAnimation(.easeInOut(duration: 0.20)) { game = 0 }
            }

            GameButton(
                title: "FREE FIRE MAX",
                subtitle: "MAX",
                selected: game == 1,
                darkMode: darkMode
            ) {
                withAnimation(.easeInOut(duration: 0.20)) { game = 1 }
            }
        }
    }

    private var currentGameSection: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 7, height: 7)

            Text(game == 0 ? "FREE FIRE" : "FREE FIRE MAX")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .tracking(1.3)

            Spacer()

            Text("\(currentOptions.count) OPTIONS")
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.dim(darkMode, 0.32))
        }
        .padding(.top, 27)
        .padding(.bottom, 13)
    }

    private var optionsListSection: some View {
        VStack(spacing: 11) {
            ForEach(currentOptions) { row in
                PatchCard(
                    row: row,
                    enabled: $enabled,
                    darkMode: darkMode
                )
            }
        }
        .id(game)
    }
}


// ============================================================
// MARK: - GAME BUTTON
// ============================================================

private struct GameButton: View {

    let title: String
    let subtitle: String
    let selected: Bool
    let darkMode: Bool
    let action: () -> Void

    // ---- helpers de color (evitan ternarios anidados) ----

    private var titleColor: Color {
        if selected {
            return darkMode ? .white : .black
        } else {
            return Theme.dim(darkMode, 0.55)
        }
    }

    private var subtitleColor: Color {
        if selected {
            return Theme.accent
        } else {
            return Theme.dim(darkMode, 0.35)
        }
    }

    private var backgroundColor: Color {
        if selected {
            return Theme.dim(darkMode, 0.085)
        } else {
            return darkMode ? Color.white.opacity(0.03) : Color.black.opacity(0.025)
        }
    }

    private var strokeColor: Color {
        if selected {
            return Theme.accent
        } else {
            return Theme.dim(darkMode, 0.10)
        }
    }

    private var strokeWidth: CGFloat {
        selected ? 1.4 : 1
    }

    var body: some View {
        Button(action: action) {
            label
        }
        .buttonStyle(.plain)
    }

    private var label: some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.system(size: 13.5, weight: .bold, design: .rounded))

            Text(subtitle)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(subtitleColor)
        }
        .foregroundStyle(titleColor)
        .frame(maxWidth: .infinity)
        .frame(height: 68)
        .background(backgroundColor)
        .overlay(
            RoundedRectangle(cornerRadius: 17)
                .stroke(strokeColor, lineWidth: strokeWidth)
        )
        .clipShape(RoundedRectangle(cornerRadius: 17))
    }
}


// ============================================================
// MARK: - PATCH CARD
// ============================================================

private struct PatchCard: View {

    let row: PatchOption
    @Binding var enabled: Set<String>
    let darkMode: Bool

    @State private var busy = false
    @State private var successPresented = false
    @State private var errorMessage: String?

    private var isEnabled: Bool {
        enabled.contains(row.id)
    }

    // ---- helpers de color ----

    private var cardBackground: Color {
        darkMode ? Color.white.opacity(0.045) : Color.black.opacity(0.035)
    }

    private var iconBackground: Color {
        darkMode ? Color.white.opacity(0.065) : Color.black.opacity(0.045)
    }

    private var iconColor: Color {
        isEnabled ? Theme.accent : Theme.dim(darkMode, 0.55)
    }

    private var titleColor: Color {
        darkMode ? .white : .black
    }

    private var subtitleColor: Color {
        Theme.dim(darkMode, 0.40)
    }

    private var strokeColor: Color {
        isEnabled
            ? Theme.accent.opacity(0.62)
            : Theme.dim(darkMode, 0.085)
    }

    private var strokeWidth: CGFloat {
        isEnabled ? 1.2 : 1
    }

    private var iconName: String {
        row.manualControls ? "scope" : "bolt.fill"
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { newValue in
                if !newValue { errorMessage = nil }
            }
        )
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { enabled.contains(row.id) },
            set: { on in
                if row.manualControls {
                    if on {
                        enabled.insert(row.id)
                    } else {
                        enabled.remove(row.id)
                    }
                } else {
                    run(row: row, enabledState: on)
                }
            }
        )
    }

    // ---- body ----

    var body: some View {
        VStack(spacing: 0) {
            mainRow

            if row.manualControls && isEnabled {
                manualControls
            }
        }
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 19)
                .stroke(strokeColor, lineWidth: strokeWidth)
        )
        .clipShape(RoundedRectangle(cornerRadius: 19))
        .animation(.easeInOut(duration: 0.18), value: isEnabled)
        .alert("Sucesso", isPresented: $successPresented) {
            Button("OK") {}
        } message: {
            Text("Ativado com sucesso!")
        }
        .alert("MOON X7", isPresented: errorBinding) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // ---- subviews ----

    private var mainRow: some View {
        HStack(spacing: 13) {
            iconView
            textColumn
            Spacer(minLength: 5)

            if busy {
                ProgressView().scaleEffect(0.75)
            }

            Toggle("", isOn: toggleBinding)
                .labelsHidden()
                .scaleEffect(0.88)
                .tint(Theme.accent)
                .disabled(busy)
        }
        .padding(15)
    }

    private var iconView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13)
                .fill(iconBackground)

            Image(systemName: iconName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(iconColor)
        }
        .frame(width: 47, height: 47)
    }

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(titleColor)

            if let subtitle = row.subtitle {
                Text(subtitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(subtitleColor)
            }
        }
    }

    private var manualControls: some View {
        HStack(spacing: 10) {
            actionCard("INJETAR (40%)") {
                runManual(row: row, apply: true)
            }
            actionCard("LOBBY") {
                runManual(row: row, apply: false)
            }
        }
        .padding(.horizontal, 15)
        .padding(.bottom, 14)
    }

    private func actionCard(
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
    }

    // ========================================================
    // RUNNERS
    // ========================================================

    private func run(row: PatchOption, enabledState: Bool) {
        guard !busy else { return }
        busy = true

        DispatchQueue.global(qos: .userInitiated).async {
            let result = PatchSlotRunner.setEnabled(
                enabledState,
                fileName: row.patchFile,
                configuredPassword: row.patchPassword
            )

            DispatchQueue.main.async {
                busy = false

                switch result {
                case .success:
                    if enabledState {
                        enabled.insert(row.id)
                        successPresented = true
                    } else {
                        enabled.remove(row.id)
                    }
                case .failure(let error):
                    errorMessage = PatchSlotRunner.message(for: error)
                }
            }
        }
    }

    private func runManual(row: PatchOption, apply: Bool) {
        guard !busy else { return }
        busy = true

        DispatchQueue.global(qos: .userInitiated).async {
            let result = PatchSlotRunner.setEnabled(
                apply,
                fileName: row.patchFile,
                configuredPassword: row.patchPassword
            )

            DispatchQueue.main.async {
                busy = false

                switch result {
                case .success:
                    if apply { successPresented = true }
                case .failure(let error):
                    errorMessage = PatchSlotRunner.message(for: error)
                }
            }
        }
    }
}


// ============================================================
// MARK: - PATCH SLOT RUNNER
// ============================================================

private enum PatchSlotRunner {

    static func setEnabled(_ enabled: Bool, fileName: String, configuredPassword: String) -> Result<String, Error> {
        do {
            let url = try bundledPatchURL(fileName: fileName)
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])

            let password: String? = configuredPassword == "0" ? nil : configuredPassword
            let decoded = try PatchPackageCodec.decode(data, password: password)

            if enabled {
                _ = try DevicePatchService.apply(project: decoded.project)
                return .success("Patch aplicado. Backup original criado.")
            } else {
                guard let receipt = DevicePatchService.latestReceipt(projectID: decoded.project.id) else {
                    throw PatchSlotError.noBackup
                }
                try DevicePatchService.restore(receipt: receipt)
                return .success("Backup restaurado. Arquivos originais recuperados.")
            }
        } catch {
            return .failure(error)
        }
    }

    static func message(for error: Error) -> String {
        if let slotError = error as? PatchSlotError {
            switch slotError {
            case .missingFile(let name):
                return "Arquivo não encontrado em Patches: \(name)"
            case .noBackup:
                return "Não existe backup aplicado para este patch."
            }
        }
        if let patchError = error as? PatchPackageError {
            return "Falha no patch: \(patchError.localizationKey)"
        }
        return "Falha: \(error.localizedDescription)"
    }

    private static func bundledPatchURL(fileName: String) throws -> URL {
        let fm = FileManager.default
        let expectedName = (fileName as NSString).lastPathComponent

        // Patches are isolated by feature. Keep these folders in the app bundle:
        // Patches/FF Normal, Patches/FF Max, Textures/
        let folders = ["Patches/FF Max", "Patches/FF Normal", "Patches"]

        if let bundleRoot = Bundle.main.resourceURL {
            for folder in folders {
                let exact = bundleRoot
                    .appendingPathComponent(folder, isDirectory: true)
                    .appendingPathComponent(expectedName, isDirectory: false)
                if fm.fileExists(atPath: exact.path) {
                    return exact
                }
            }

            if let enumerator = fm.enumerator(
                at: bundleRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                for case let candidate as URL in enumerator {
                    if candidate.lastPathComponent == expectedName,
                       fm.fileExists(atPath: candidate.path) {
                        return candidate
                    }
                }
            }
        }

        let ns = expectedName as NSString
        let resource = ns.deletingPathExtension
        let ext = ns.pathExtension.isEmpty ? "3105" : ns.pathExtension

        for folder in ["Patches/FF Max", "Patches/FF Normal", "Patches"] {
            if let url = Bundle.main.url(forResource: resource, withExtension: ext, subdirectory: folder) {
                return url
            }
        }

        if let url = Bundle.main.url(forResource: resource, withExtension: ext) {
            return url
        }

        throw PatchSlotError.missingFile(expectedName)
    }

    private enum PatchSlotError: Error {
        case missingFile(String)
        case noBackup
    }
}


// ============================================================
// MARK: - TEXTURAS VIEW
// ============================================================

private struct PreviewItem: Identifiable {
    let id: String
    let title: String
    let fileName: String
    let imageName: String
}

private struct PreviewView: View {
    let darkMode: Bool

    private let items: [PreviewItem] = [
        PreviewItem(id: "preview-01", title: "ARM HOLO BORDE AZUL Y ROJO", fileName: "ARM HOLO BORDE AZUL Y ROJO.3105", imageName: "preview-01"),
        PreviewItem(id: "preview-02", title: "ARM HOLO BORDE RTX", fileName: "ARM HOLO BORDE RTX.3105", imageName: "preview-02"),
        PreviewItem(id: "preview-03", title: "ARM HOLO BORDE VERDE AMARILLO", fileName: "ARM HOLO BORDE VERDE AMARILLO.3105", imageName: "preview-03"),
        PreviewItem(id: "preview-04", title: "PJ HOLO MOON VIP", fileName: "PJ HOLO MOON VIP.3105", imageName: "preview-04"),
        PreviewItem(id: "preview-05", title: "PJ HOLO ROBOT AMARILLO", fileName: "PJ HOLO ROBOT AMARILLO.3105", imageName: "preview-05"),
        PreviewItem(id: "preview-06", title: "PJ HOLO ROBOT CIAN", fileName: "PJ HOLO ROBOT CIAN.3105", imageName: "preview-06"),
        PreviewItem(id: "preview-07", title: "PJ HOLO ROBOT ROJO", fileName: "PJ HOLO ROBOT ROJO.3105", imageName: "preview-07"),
        PreviewItem(id: "preview-08", title: "EXTRA PREVIEW", fileName: "", imageName: "preview-08")
    ]

    private var background: Color {
        darkMode ? Color.black : Color(uiColor: .systemGroupedBackground)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Text("MOON")
                        .font(.system(size: 34, weight: .black, design: .rounded))
                        .tracking(4)
                    Text("PREVIEW GALLERY")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(2.6)
                        .foregroundStyle(Theme.accent)
                    Text("Vista previa de las opciones antes de aplicarlas.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.dim(darkMode, 0.42))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 68)
                .padding(.bottom, 24)

                AnimatedGIFView(filename: "realm-banner.gif")
                    .frame(height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Theme.accent.opacity(0.30), lineWidth: 1)
                    }
                    .shadow(color: Theme.accent.opacity(0.16), radius: 20, y: 8)
                    .padding(.bottom, 22)

                VStack(spacing: 13) {
                    ForEach(items) { item in
                        PreviewCard(item: item, darkMode: darkMode)
                    }
                }

                Spacer().frame(height: 100)
            }
            .padding(.horizontal, 20)
        }
        .background(background.ignoresSafeArea())
    }
}

private struct PreviewCard: View {
    let item: PreviewItem
    let darkMode: Bool
    @State private var showPreview = false

    private var mediaURL: URL? {
        guard let root = Bundle.main.resourceURL else { return nil }
        let directory = root.appendingPathComponent("PreviewImages", isDirectory: true)
        for ext in ["jpg", "jpeg", "png", "webp", "gif", "mp4", "mov", "m4v"] {
            let url = directory.appendingPathComponent("\(item.imageName).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Theme.accent.opacity(0.10))
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title)
                        .font(.system(size: 14.5, weight: .bold, design: .rounded))
                        .foregroundStyle(darkMode ? .white : .black)
                        .lineLimit(2)
                    Text("PREVIEW • \(item.imageName).jpg")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.dim(darkMode, 0.38))
                }

                Spacer()
            }
            .padding(15)

            Button {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                    showPreview.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: showPreview ? "eye.slash.fill" : "eye.fill")
                    Text(showPreview ? "OCULTAR PREVIEW" : "VER PREVIEW")
                }
                .font(.system(size: 12, weight: .black, design: .rounded))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    LinearGradient(
                        colors: [Theme.accent, Theme.accentAlt],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 15)
            .padding(.bottom, 15)

            if showPreview {
                Group {
                    if let url = mediaURL {
                        PreviewMediaView(url: url)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 180, maxHeight: 380)
                            .background(Color.black.opacity(0.20))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(Theme.accent.opacity(0.85))
                            Text("Sube la imagen en PreviewImages/\(item.imageName).jpg")
                                .font(.system(size: 12, weight: .semibold))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(Theme.dim(darkMode, 0.58))
                            Text("La carpeta ya está preparada en el repositorio.")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Theme.dim(darkMode, 0.35))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 180)
                        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding(.horizontal, 15)
                .padding(.bottom, 15)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .background(darkMode ? Color.white.opacity(0.045) : Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 21, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .stroke(Theme.accent.opacity(showPreview ? 0.38 : 0.10), lineWidth: showPreview ? 1.2 : 1)
        }
        .animation(.easeInOut(duration: 0.22), value: showPreview)
    }
}


private struct PreviewMediaView: View {
    let url: URL

    var body: some View {
        switch url.pathExtension.lowercased() {
        case "gif":
            AnimatedGIFView(filename: url.lastPathComponent)
        case "mp4", "mov", "m4v":
            VideoPlayer(player: AVPlayer(url: url))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        default:
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
    }
}

// ============================================================
// MARK: - CONFIG DASHBOARD VIEW
// ============================================================

private struct ConfigDashboardView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var auth: MoonAuthManager
    @Binding var darkMode: Bool
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RadialGradient(colors: [Theme.accent.opacity(0.16), .clear], center: .topTrailing, startRadius: 0, endRadius: 420)
                .ignoresSafeArea()
            RadialGradient(colors: [Theme.violet.opacity(0.12), .clear], center: .bottomLeading, startRadius: 0, endRadius: 500)
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("CONFIG")
                                .font(.system(size: 32, weight: .black, design: .rounded))
                                .tracking(2.2)
                                .foregroundStyle(.white)
                            Text("LICENSE • DEVICE • APPEARANCE")
                                .font(.system(size: 8.5, weight: .black, design: .rounded))
                                .tracking(1.4)
                                .foregroundStyle(Theme.accent)
                        }
                        Spacer()
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(.white.opacity(0.06), in: Circle())
                                .overlay(Circle().stroke(.white.opacity(0.10)))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 62)

                    VStack(alignment: .leading, spacing: 15) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("LICENSE STATUS")
                                    .font(.system(size: 9, weight: .black, design: .rounded))
                                    .tracking(1.4)
                                    .foregroundStyle(Theme.accent)
                                Text(auth.isAuthenticated ? "ACTIVA" : "SIN SESIÓN")
                                    .font(.system(size: 25, weight: .black, design: .rounded))
                                    .foregroundStyle(.white)
                            }
                            Spacer()
                            Image(systemName: auth.isAuthenticated ? "checkmark.shield.fill" : "xmark.shield.fill")
                                .font(.system(size: 34, weight: .bold))
                                .foregroundStyle(auth.isAuthenticated ? .green : Theme.accent)
                        }
                        configRow("KEY", auth.licenseKey ?? "—", mono: true)
                        configRow("PLAN", auth.plan?.uppercased() ?? "—")
                        configRow("DURACIÓN", durationText)
                        configRow("ACTIVADA", activationText)
                        configRow("EXPIRA", expiryText)
                        configRow("RESTANTE", remainingText)
                        HStack(spacing: 9) {
                            statCard("BUILD", "6")
                            statCard("VERSION", "1.1")
                        }
                    }
                    .padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(LinearGradient(colors: [Theme.accent.opacity(0.55), .white.opacity(0.08), Theme.violet.opacity(0.32)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                    }

                    VStack(alignment: .leading, spacing: 13) {
                        Text("DEVICE")
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .tracking(1.4)
                            .foregroundStyle(Theme.accent)
                        configRow("MODEL", DeviceInfo.machine)
                        configRow("IOS", UIDevice.current.systemVersion)
                        HStack {
                            Text("COMPATIBILITY")
                                .font(.system(size: 9, weight: .black, design: .rounded))
                                .foregroundStyle(.white.opacity(0.34))
                            Spacer()
                            Label(appState.isSupported ? "SUPPORTED" : "NOT SUPPORTED", systemImage: appState.isSupported ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 9, weight: .black, design: .rounded))
                                .foregroundStyle(appState.isSupported ? .green : Theme.accent)
                        }
                    }
                    .padding(18)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.08)))

                    HStack {
                        Label(darkMode ? "Modo oscuro" : "Modo claro", systemImage: darkMode ? "moon.fill" : "sun.max.fill")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Spacer()
                        Toggle("", isOn: $darkMode).labelsHidden().tint(Theme.accent)
                    }
                    .padding(18)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.08)))

                    Spacer().frame(height: 100)
                }
                .padding(.horizontal, 18)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().preferredColorScheme(darkMode ? .dark : .light)
        }
    }

    private func configRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 9, weight: .black, design: .rounded))
                .tracking(1)
                .foregroundStyle(.white.opacity(0.32))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .bold, design: mono ? .monospaced : .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private func statCard(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 8, weight: .black, design: .rounded)).foregroundStyle(.black.opacity(0.55))
            Text(value).font(.system(size: 14, weight: .black, design: .rounded)).foregroundStyle(.black)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.silver, in: RoundedRectangle(cornerRadius: 13))
    }

    private var durationText: String {
        guard let days = auth.durationDays else {
            return auth.plan?.lowercased() == "lifetime" ? "LIFETIME" : "—"
        }
        return days == 1 ? "1 día" : "\(days) días"
    }

    private var activationText: String {
        guard let date = auth.activatedAt else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var expiryText: String {
        guard let date = auth.expiresAt else {
            return auth.plan?.lowercased() == "lifetime" ? "SIN EXPIRACIÓN" : "—"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var remainingText: String {
        guard let date = auth.expiresAt else { return "—" }
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

// ============================================================
// MARK: - ANIMATED GIF
// ============================================================

private struct AnimatedGIFView: UIViewRepresentable {
    let filename: String

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.backgroundColor = .clear
        view.image = animatedImage()
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        if uiView.image == nil {
            uiView.image = animatedImage()
        }
    }

    private func animatedImage() -> UIImage? {
        guard
            let url = Bundle.main.url(forResource: filename, withExtension: nil),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }

        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        var frames: [UIImage] = []
        var duration: TimeInterval = 0.0

        for index in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(UIImage(cgImage: cgImage))
            duration += frameDuration(source: source, index: index)
        }

        guard !frames.isEmpty else { return nil }
        return UIImage.animatedImage(with: frames, duration: max(duration, 0.8))
    }

    private func frameDuration(source: CGImageSource, index: Int) -> TimeInterval {
        let defaultDuration = 0.08
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
            let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return defaultDuration }

        let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
        return max(unclamped ?? clamped ?? defaultDuration, 0.02)
    }
}

// ============================================================
// MARK: - DEVICE INFO
// ============================================================

private enum DeviceInfo {
    static var machine: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
    }
}


// ============================================================
// MARK: - BOTTOM ITEM
// ============================================================

private struct BottomItem: View {
    let icon: String
    let title: String
    let selected: Bool
    let darkMode: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 18, weight: .black))
                Text(title).font(.system(size: 10, weight: .black, design: .rounded)).tracking(0.4)
            }
            .foregroundStyle(selected ? Theme.silver : Theme.dim(darkMode, 0.46))
            .frame(maxWidth: .infinity).frame(height: 56)
            .background(selected ? Theme.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.accent.opacity(0.50), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

import SwiftUI
import Foundation
import UIKit
import Security
import ImageIO
import AVKit

// ============================================================
// MARK: - CONTENT VIEW
// ============================================================

private let moonX7UIBuildStamp = "MOON-X7 • REDESIGN • 2.2.0 • METALLIC EDITION"

private enum MoonRemoteMedia {
    static let dashboardBanner = "https://media3.giphy.com/media/0WrS97JxpzwmTPbviV/giphy.gif?cid=9b38fe91uxzhi4x5aq594g2wnsczkch3iyao9zsd0knbsbr5&ep=v1_channels_id_gifs&rid=giphy.gif&ct=g"
    static let loginBanner = "https://media0.giphy.com/media/zn5a8GjiDwu0VNrPMU/giphy.gif?cid=9b38fe91f7v98wdew07jfl146qpm6wsl8bpy65wr4q4hjjjl&ep=v1_gifs_search&rid=giphy.gif&ct=g"
}

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
                MoonX7V2LoginView(auth: auth)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var authenticatedView: some View {
        MoonX7V2Shell(auth: auth, darkMode: $darkMode)
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
                    Spacer(minLength: 24)

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
                        .frame(maxWidth: .infinity)
                        .frame(height: 118)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [cyan.opacity(0.50), moon.opacity(0.45)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ),
                                    lineWidth: 1
                                )
                        }
                        .shadow(color: moon.opacity(0.22), radius: 20, y: 9)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 14)

                    Text("MOON X7")
                        .font(.system(size: 32, weight: .black, design: .rounded))
                        .tracking(3.2)
                        .foregroundStyle(.white)
                        .padding(.top, 18)

                    Text(moonX7UIBuildStamp)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.30))
                        .padding(.top, 5)

                    Text("ACCESS CONTROL")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(3.2)
                        .foregroundStyle(cyan.opacity(0.82))
                        .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 18) {
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

                            HStack(spacing: 9) {
                                Image(systemName: "key.horizontal.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(cyan)
                                    .frame(width: 20)

                                TextField("MOONX7-XXXX-XXXX", text: $licenseKey)
                                    .textInputAutocapitalization(.characters)
                                    .autocorrectionDisabled()
                                    .foregroundStyle(.white)
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.78)
                                    .layoutPriority(1)

                                Button {
                                    licenseKey = UIPasteboard.general.string ?? licenseKey
                                } label: {
                                    Text("PEGAR")
                                        .font(.system(size: 10, weight: .black, design: .rounded))
                                        .foregroundStyle(cyan)
                                        .frame(width: 54, height: 32)
                                        .background(cyan.opacity(0.12), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .fixedSize()
                                .accessibilityLabel("Pegar key desde el portapapeles")
                            }
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
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
                    .padding(17)
                    .background(panel.opacity(0.94), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RGBGlowBorder(cornerRadius: 22, lineWidth: 1.1)
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 22)

                    Text("MOONX7 • SECURE LICENSE ACCESS")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.32))
                        .padding(.top, 22)
                        .padding(.bottom, 30)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
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
    // FREE FIRE NORMAL
    static let ffn1 = "MOON CABEZA.3105"
    static let ffn2 = "MOON CABEZA ATN.3105"
    static let ffn3 = "MOON CUELLO.3105"
    static let ffn4 = "MOON CUELLO ATN.3105"
    static let ffn5 = "MOON DRAG.3105"
    static let ffn6 = "MOON DRAG ATN.3105"
    static let ffn7 = "MOON PECHO.3105"
    static let ffn8 = "MOON PECHO ATN.3105"
    static let ffnFPS = "120-144 FPS FF.3105"

    // FREE FIRE MAX
    static let ffmxFPS = "120-144 FPS FFMAX.3105"

    // Passwords
    static let password = "moonx7"
    static let armHoloPassword = "moonx7"
    static let pjHoloPassword = "0"
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

    private let freeFireOptions: [PatchOption] = [
        PatchOption(id: "ffn-01", title: "MOON CABEZA", subtitle: "FF NORMAL", patchFile: PatchSlots.ffn1, patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "ffn-02", title: "MOON CABEZA ATN", subtitle: "FF NORMAL", patchFile: PatchSlots.ffn2, patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "ffn-03", title: "MOON CUELLO", subtitle: "FF NORMAL", patchFile: PatchSlots.ffn3, patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "ffn-04", title: "MOON CUELLO ATN", subtitle: "FF NORMAL", patchFile: PatchSlots.ffn4, patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "ffn-05", title: "MOON DRAG", subtitle: "FF NORMAL", patchFile: PatchSlots.ffn5, patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "ffn-06", title: "MOON DRAG ATN", subtitle: "FF NORMAL", patchFile: PatchSlots.ffn6, patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "ffn-07", title: "MOON PECHO", subtitle: "FF NORMAL", patchFile: PatchSlots.ffn7, patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "ffn-08", title: "MOON PECHO ATN", subtitle: "FF NORMAL", patchFile: PatchSlots.ffn8, patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "ffn-120fps", title: "120–144 FPS", subtitle: "FF NORMAL • FPS", patchFile: PatchSlots.ffnFPS, patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "ffn-arm-holo", title: "ARM HOLO MOON • RAINBOW", subtitle: "FF NORMAL • HOLO ARM", patchFile: "ARM HOLO MOON RAINBOW.3105", patchPassword: PatchSlots.armHoloPassword, manualControls: true, isTexture: true)
    ]

    // --------------------------------------------------------
    // FREE FIRE MAX
    // --------------------------------------------------------

    private let freeFireMaxOptions: [PatchOption] = [
        PatchOption(id: "ffmx-01", title: "AIM MOON CABEZA", subtitle: "FF MAX • AIM MOON", patchFile: "AIM MOON CABEZA.3105", patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "ffmx-02", title: "AIM MOON CABEZA ATN", subtitle: "FF MAX • AIM MOON", patchFile: "AIM MOON CABEZA ATN.3105", patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "ffmx-03", title: "AIM MOON CUELLO", subtitle: "FF MAX • AIM MOON", patchFile: "AIM MOON CUELLO.3105", patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "ffmx-04", title: "AIM MOON CUELLO ATN", subtitle: "FF MAX • AIM MOON", patchFile: "AIM MOON CUELLO ATN.3105", patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "ffmx-05", title: "AIM MOON DRAG", subtitle: "FF MAX • AIM MOON", patchFile: "AIM MOON DRAG.3105", patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "ffmx-06", title: "AIM MOON DRAG ATN", subtitle: "FF MAX • AIM MOON", patchFile: "AIM MOON DRAG ATN.3105", patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "ffmx-07", title: "AIM MOON PECHO", subtitle: "FF MAX • AIM MOON", patchFile: "AIM MOON PECHO.3105", patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "ffmx-08", title: "AIM MOON PECHO ATN", subtitle: "FF MAX • AIM MOON", patchFile: "AIM MOON PECHO ATN.3105", patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "ffmx-120fps", title: "120–144 FPS", subtitle: "FF MAX • FPS", patchFile: PatchSlots.ffmxFPS, patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "r-arm-normal-rainbow", title: "ARM MOON SPIN • RAINBOW", subtitle: "FF MAX • HOLO ARM", patchFile: "ARM MOON SPIN RAINBOW.3105", patchPassword: PatchSlots.armHoloPassword, manualControls: true, isTexture: true),
        PatchOption(id: "r-pj1", title: "PJ HOLO • COTTON CANDY", subtitle: "FF MAX • PJ HOLO", patchFile: "PJ HOLO MOON COTTON CANDY.3105", patchPassword: PatchSlots.pjHoloPassword, manualControls: true, isTexture: true),
        PatchOption(id: "r-pj2", title: "PJ HOLO • DARK GALAXY", subtitle: "FF MAX • PJ HOLO", patchFile: "PJ HOLO MOON DARK GALAXY.3105", patchPassword: PatchSlots.pjHoloPassword, manualControls: true, isTexture: true),
        PatchOption(id: "r-pj3", title: "PJ HOLO • ESPEJOS", subtitle: "FF MAX • PJ HOLO", patchFile: "PJ HOLO MOON ESPEJOS.3105", patchPassword: PatchSlots.pjHoloPassword, manualControls: true, isTexture: true)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
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
                    Text(moonX7UIBuildStamp)
                        .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.30))
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
                    .frame(maxWidth: .infinity)
                    .frame(height: 146)
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
                    Text("3 PJ HOLO • NEW COLLECTION")
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
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)

            if let subtitle = row.subtitle {
                Text(subtitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(subtitleColor)
            }
        }
    }

    private var manualControls: some View {
        HStack(spacing: 10) {
            actionCard(row.isTexture ? "INJETAR" : "INJETAR (40%)") {
                runManual(row: row, apply: true)
            }
            actionCard(row.isTexture ? "QUITAR" : "LOBBY") {
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
                slotID: row.id,
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
                slotID: row.id,
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
// MARK: - PERSISTENT ACTIVE PATCH RECEIPTS
// ============================================================

private enum ActivePatchReceipts {
    private static let prefix = "moonx7.activePatchReceipt."

    private struct StoredReceipt: Codable {
        let id: UUID
        let projectID: UUID
    }

    static func save(_ receipt: PatchTransactionReceipt, for slotID: String) {
        let value = StoredReceipt(id: receipt.id, projectID: receipt.projectID)
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key(slotID))
    }

    static func load(for slotID: String) -> PatchTransactionReceipt? {
        guard let data = UserDefaults.standard.data(forKey: key(slotID)),
              let stored = try? JSONDecoder().decode(StoredReceipt.self, from: data),
              let backupRoot = try? PatchProjectLibrary.backupRootURL() else {
            return nil
        }

        let journalURL = backupRoot
            .appendingPathComponent(stored.projectID.uuidString, isDirectory: true)
            .appendingPathComponent(stored.id.uuidString, isDirectory: true)
            .appendingPathComponent("journal.plist", isDirectory: false)

        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            return nil
        }

        return PatchTransactionReceipt(
            id: stored.id,
            projectID: stored.projectID,
            journalURL: journalURL
        )
    }

    static func remove(for slotID: String) {
        UserDefaults.standard.removeObject(forKey: key(slotID))
    }

    private static func key(_ slotID: String) -> String {
        prefix + slotID
    }
}

// ============================================================
// MARK: - PATCH SLOT RUNNER
// ============================================================

private enum PatchSlotRunner {

    static func setEnabled(_ enabled: Bool, slotID: String, fileName: String, configuredPassword: String) -> Result<String, Error> {
        do {
            let url = try bundledPatchURL(fileName: fileName)
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])

            let password: String? = configuredPassword == "0" ? nil : configuredPassword
            let decoded = try PatchPackageCodec.decode(data, password: password)

            if enabled {
                let receipt = try DevicePatchService.apply(project: decoded.project)
                ActivePatchReceipts.save(receipt, for: slotID)
                return .success("Patch aplicado. Backup original criado.")
            } else {
                guard let receipt = ActivePatchReceipts.load(for: slotID)
                    ?? DevicePatchService.latestReceipt(projectID: decoded.project.id) else {
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
        PreviewItem(id: "preview-cotton-candy", title: "PJ HOLO MOON COTTON CANDY", fileName: "PJ HOLO MOON COTTON CANDY.3105", imageName: "PJ HOLO MOON COTTON CANDY.mp4"),
        PreviewItem(id: "preview-dark-galaxy", title: "PJ HOLO MOON DARK GALAXY", fileName: "PJ HOLO MOON DARK GALAXY.3105", imageName: "PJ HOLO MOON DARK GALAXY.mp4"),
        PreviewItem(id: "preview-espejos", title: "PJ HOLO MOON ESPEJOS", fileName: "PJ HOLO MOON ESPEJOS.3105", imageName: "PJ HOLO MOON ESPEJOS.mp4")
    
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
                .padding(.top, 48)
                .padding(.bottom, 20)

                AnimatedGIFView(filename: "realm-banner.gif")
                    .frame(maxWidth: .infinity)
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
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 14)
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
        let url = directory.appendingPathComponent(item.imageName, isDirectory: false)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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
                    Text("VIDEO PREVIEW • \(item.imageName)")
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
                            Text("Falta el video en PreviewImages/\(item.imageName)")
                                .font(.system(size: 12, weight: .semibold))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(Theme.dim(darkMode, 0.58))
                            Text("El video se carga directamente desde el bundle de la app.")
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
            if showPreview {
                RGBGlowBorder(cornerRadius: 21, lineWidth: 1.1)
            } else {
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .stroke(Theme.accent.opacity(0.10), lineWidth: 1)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: showPreview)
    }
}



private struct CleanVideoPlayer: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.backgroundColor = .black
        view.playerLayer.player = AVPlayer(url: url)
        view.playerLayer.videoGravity = .resizeAspectFill
        context.coordinator.player = view.playerLayer.player
        view.onTap = {
            guard let player = context.coordinator.player else { return }
            if player.timeControlStatus == .playing {
                player.pause()
            } else {
                player.play()
            }
        }
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {}

    final class Coordinator {
        var player: AVPlayer?
    }
}

private final class PlayerContainerView: UIView {
    let playerLayer = AVPlayerLayer()
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(playerLayer)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        layer.addSublayer(playerLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }

    @objc private func tapped() {
        onTap?()
    }
}

private struct PreviewMediaView: View {
    let url: URL

    var body: some View {
        switch url.pathExtension.lowercased() {
        case "gif":
            AnimatedGIFView(filename: url.lastPathComponent)
        case "mp4", "mov", "m4v":
            CleanVideoPlayer(url: url)
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
                                .font(.system(size: 30, weight: .black, design: .rounded))
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
                                .frame(width: 40, height: 40)
                                .background(.white.opacity(0.06), in: Circle())
                                .overlay(Circle().stroke(.white.opacity(0.10)))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 46)

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
                            statCard("BUILD", "7")
                            statCard("VERSION", "2.0.0")
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

                    VStack(alignment: .leading, spacing: 12) {
                        Text("SOCIAL / CONTACT")
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .tracking(1.4)
                            .foregroundStyle(Theme.accent)

                        VStack(spacing: 9) {
                            SocialLinkButton(title: "WhatsApp • Contact Dev", icon: "message.fill", urlString: MoonSocialLinks.whatsapp)
                            SocialLinkButton(title: "YouTube", icon: "play.rectangle.fill", urlString: MoonSocialLinks.youtube)
                            SocialLinkButton(title: "Discord", icon: "bubble.left.and.bubble.right.fill", urlString: MoonSocialLinks.discord)
                            SocialLinkButton(title: "Telegram", icon: "paperplane.fill", urlString: MoonSocialLinks.telegram)
                            SocialLinkButton(title: "Web", icon: "globe", urlString: MoonSocialLinks.web)
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
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
                .lineLimit(3)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: 190, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
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

private enum MoonSocialLinks {
    // Reemplazar estos cinco valores por tus enlaces reales.
    static let whatsapp = "https://wa.me/529811958565?text=Quiero%20contactar%20al%20developer%20moon"
    static let youtube = "https://www.youtube.com/@MOONZADA.H4X"
    static let discord = "https://discord.gg/hD6qXCtXm"
    static let telegram = "https://t.me/moonzazax7?text=I%20want%20contact%20the%20dev%20"
    static let web = ""
}

private struct SocialLinkButton: View {
    let title: String
    let icon: String
    let urlString: String

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            guard let url = URL(string: urlString), !urlString.isEmpty else { return }
            openURL(url)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 24)

                Text(title)
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .black))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.accent.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .disabled(urlString.isEmpty)
        .opacity(urlString.isEmpty ? 0.45 : 1)
    }
}

// ============================================================
// MARK: - ANIMATED GIF// ============================================================
// MARK: - ANIMATED GIF
// ============================================================

private struct RGBGlowBorder: View {
    let cornerRadius: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 8.0) / 8.0
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    AngularGradient(
                        colors: [
                            Color.red,
                            Color.orange,
                            Color.yellow,
                            Color.green,
                            Color.cyan,
                            Color.blue,
                            Color.purple,
                            Color.red
                        ],
                        center: .center,
                        angle: .degrees(phase * 360)
                    ),
                    lineWidth: lineWidth
                )
                .shadow(color: Color.cyan.opacity(0.22), radius: 7)
        }
        .allowsHitTesting(false)
    }
}

private struct AnimatedGIFView: UIViewRepresentable {
    let filename: String
    @ObservedObject private var capture = MoonCaptureState.shared

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = false
        view.backgroundColor = .clear
        view.image = animatedImage()
        if capture.isCaptured {
            view.stopAnimating()
        } else {
            view.startAnimating()
        }
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        if uiView.image == nil {
            uiView.image = animatedImage()
        }
        if capture.isCaptured {
            uiView.stopAnimating()
        } else {
            uiView.startAnimating()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIImageView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let height = proposal.height ?? 120
        return CGSize(width: max(1, width), height: max(1, height))
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
private struct RemoteAnimatedGIFView: UIViewRepresentable {
    let urlString: String
    let contentMode: UIView.ContentMode
    @ObservedObject private var capture = MoonCaptureState.shared

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = contentMode
        view.clipsToBounds = true
        view.backgroundColor = .clear
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        load(into: view)
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        if uiView.image == nil {
            load(into: uiView)
        }
        if capture.isCaptured {
            uiView.stopAnimating()
        } else {
            uiView.startAnimating()
        }
    }

    private func load(into imageView: UIImageView) {
        guard let url = URL(string: urlString) else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data,
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return }

            let count = CGImageSourceGetCount(source)
            guard count > 0 else { return }

            var frames: [UIImage] = []
            var duration: TimeInterval = 0

            for index in 0..<count {
                guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
                frames.append(UIImage(cgImage: cgImage))
                duration += Self.frameDuration(source: source, index: index)
            }

            guard !frames.isEmpty else { return }
            let animated = UIImage.animatedImage(with: frames, duration: max(duration, 0.8))

            DispatchQueue.main.async {
                imageView.image = animated
            }
        }.resume()
    }

    private static func frameDuration(source: CGImageSource, index: Int) -> TimeInterval {
        let fallback = 0.08
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
            let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return fallback }

        let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
        return max(unclamped ?? clamped ?? fallback, 0.02)
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
                    RGBGlowBorder(cornerRadius: 18, lineWidth: 1.15)
                }
            }
        }
        .buttonStyle(.plain)
    }
}


// ============================================================
// MARK: - MOON X7 LIQUID GLASS REDESIGN
// ============================================================

private struct MoonBootView: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            MoonAnimatedBackground()
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(Theme.accent.opacity(0.18))
                        .frame(width: 130, height: 130)
                        .blur(radius: 24)
                        .scaleEffect(pulse ? 1.18 : 0.86)
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 54, weight: .black))
                        .foregroundStyle(LinearGradient(colors: [Theme.silver, Theme.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                Text("MOON X7")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(.white)
                ProgressView()
                    .tint(Theme.accent)
                Text("VALIDANDO ACCESO")
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.42))
            }
        }
        .onAppear { withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

private final class MoonCaptureState: ObservableObject {
    static let shared = MoonCaptureState()

    @Published private(set) var isCaptured = UIScreen.main.isCaptured

    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isCaptured = UIScreen.main.isCaptured
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

private struct MoonAnimatedBackground: View {
    @ObservedObject private var capture = MoonCaptureState.shared

    var body: some View {
        Group {
            if capture.isCaptured {
                Color.black
                    .ignoresSafeArea()
                    .overlay {
                        LinearGradient(
                            colors: [
                                Theme.accent.opacity(0.045),
                                .clear,
                                Theme.violet.opacity(0.035)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .ignoresSafeArea()
                    }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate

                    ZStack {
                        Color.black.ignoresSafeArea()

                        Circle()
                            .fill(Theme.accent.opacity(0.18))
                            .frame(width: 360, height: 360)
                            .blur(radius: 78)
                            .offset(
                                x: CGFloat(sin(t * 0.34) * 155.0),
                                y: CGFloat(-245.0 + cos(t * 0.22) * 55.0)
                            )

                        Circle()
                            .fill(Color.orange.opacity(0.075))
                            .frame(width: 300, height: 300)
                            .blur(radius: 85)
                            .offset(
                                x: CGFloat(cos(t * 0.28) * 165.0),
                                y: CGFloat(185.0 + sin(t * 0.31) * 80.0)
                            )

                        Circle()
                            .fill(Theme.violet.opacity(0.13))
                            .frame(width: 390, height: 390)
                            .blur(radius: 92)
                            .offset(
                                x: CGFloat(sin(t * 0.19 + 2.4) * 150.0),
                                y: CGFloat(330.0 + cos(t * 0.17) * 70.0)
                            )

                        ForEach(0..<14, id: \.self) { index in
                            let seed = Double(index)
                            let x = sin(t * (0.20 + seed * 0.012) + seed * 1.73) * 180.0
                            let y = cos(t * (0.27 + seed * 0.009) + seed * 2.11) * 390.0
                            let size = 2.0 + seed.truncatingRemainder(dividingBy: 3.0)

                            Circle()
                                .fill(index.isMultiple(of: 3) ? Color.orange.opacity(0.55) : Theme.accent.opacity(0.48))
                                .frame(width: size, height: size)
                                .blur(radius: 1.0)
                                .offset(x: CGFloat(x), y: CGFloat(y))
                        }

                        ForEach(0..<4, id: \.self) { index in
                            MoonLightningBolt(phase: t, index: index)
                        }

                        LinearGradient(
                            colors: [.black.opacity(0.08), .clear, Theme.accent.opacity(0.035), .black.opacity(0.16)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .ignoresSafeArea()
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct MoonLightningBolt: View {
    let phase: TimeInterval
    let index: Int

    private var flash: Double {
        let wave = sin(phase * (0.75 + Double(index) * 0.08) + Double(index) * 1.9)
        return max(0.0, wave * wave * wave)
    }

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 50, y: 0))
            path.addLine(to: CGPoint(x: 28, y: 62))
            path.addLine(to: CGPoint(x: 45, y: 57))
            path.addLine(to: CGPoint(x: 18, y: 128))
            path.addLine(to: CGPoint(x: 68, y: 52))
            path.addLine(to: CGPoint(x: 51, y: 58))
            path.closeSubpath()
        }
        .fill(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.88 * flash),
                    Theme.accent.opacity(0.82 * flash),
                    Color.orange.opacity(0.18 * flash)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .frame(width: 90, height: 145)
        .rotationEffect(.degrees(-18 + Double(index) * 31.0))
        .offset(
            x: CGFloat(-145.0 + Double(index) * 96.0),
            y: CGFloat(-115.0 + sin(phase * 0.31 + Double(index)) * 135.0)
        )
        .opacity(0.18 + flash * 0.82)
        .blur(radius: flash > 0.65 ? 0.0 : 0.8)
        .shadow(color: Theme.accent.opacity(0.40 * flash), radius: 16)
    }
}

private extension View {
    @ViewBuilder
    func moonGlass(cornerRadius: CGFloat = 22, tint: Color = Theme.accent) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.tint(tint.opacity(0.16)), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 1)
                }
        }
    }
}

private extension View {
    @ViewBuilder
    func moonGlassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}

private struct MoonX7RedesignedShell: View {
    @ObservedObject var auth: MoonAuthManager
    @Binding var darkMode: Bool
    @State private var tab = 0
    @State private var appeared = false
    @State private var showDeveloperSupport = true
    @State private var supportReady = false

    private let tabs = [
        ("house.fill", "Inicio"),
        ("bolt.horizontal.fill", "Funciones"),
        ("play.rectangle.fill", "Preview"),
        ("gearshape.fill", "Config")
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            MoonAnimatedBackground()

            Group {
                switch tab {
                case 0: MoonHomeRedesign(auth: auth, tab: $tab)
                case 1: MoonFunctionsRedesign(darkMode: darkMode)
                case 2: MoonPreviewRedesign()
                default: MoonConfigRedesign(auth: auth)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity.combined(with: .scale(scale: 0.985)))

            if showDeveloperSupport {
                MoonDeveloperSupportOverlay(
                    supportReady: $supportReady,
                    dismiss: {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                            showDeveloperSupport = false
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
                .zIndex(20)
            }

            HStack(spacing: 7) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { index, item in
                    Button {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { tab = index }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: item.0)
                                .font(.system(size: 15, weight: .bold))
                            Text(item.1)
                                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(tab == index ? .white : .white.opacity(0.42))
                        .frame(maxWidth: .infinity)
                        .frame(height: 51)
                        .background {
                            if tab == index {
                                Capsule().fill(Theme.accent.opacity(0.24))
                                    .overlay(Capsule().stroke(Theme.accent.opacity(0.55), lineWidth: 1))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(7)
            .background(.black.opacity(0.55), in: Capsule())
            .moonGlass(cornerRadius: 28, tint: Theme.accent)
            .padding(.horizontal, 14)
            .padding(.bottom, 7)
        }
        .onAppear {
            withAnimation(.spring(response: 0.65, dampingFraction: 0.82)) { appeared = true }
            supportReady = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) {
                withAnimation(.spring(response: 0.52, dampingFraction: 0.82)) {
                    supportReady = true
                }
            }
        }
    }
}

private struct MoonDeveloperSupportOverlay: View {
    @Binding var supportReady: Bool
    let dismiss: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var pulse = false

    private let discordURL = URL(string: MoonSocialLinks.discord)!

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(Theme.accent.opacity(0.20))
                        .frame(width: 118, height: 118)
                        .blur(radius: 20)
                        .scaleEffect(pulse ? 1.16 : 0.86)

                    Circle()
                        .stroke(
                            AngularGradient(
                                colors: [Theme.accent, Theme.violet, .white, Theme.accent],
                                center: .center
                            ),
                            lineWidth: 2
                        )
                        .frame(width: 78, height: 78)
                        .rotationEffect(.degrees(pulse ? 360 : 0))

                    Image(systemName: supportReady ? "person.2.fill" : "ellipsis")
                        .font(.system(size: 27, weight: .black))
                        .foregroundStyle(.white)
                }
                .padding(.top, 22)
                .padding(.bottom, 14)

                Text("MOON X7")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .tracking(2.2)
                    .foregroundStyle(Theme.accent)

                Text(supportReady ? "NO OLVIDES APOYAR AL DEVELOPER" : "CARGANDO PANEL...")
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.top, 7)

                Text(supportReady
                     ? "Únete al Discord para recibir avisos, novedades y soporte de MOON X7."
                     : "Preparando tu sesión segura...")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.52))
                    .padding(.horizontal, 24)
                    .padding(.top, 9)

                if supportReady {
                    Button {
                        openURL(discordURL)
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                            Text("UNIRME AL DISCORD")
                        }
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                    }
                    .moonGlassButton(prominent: true)
                    .tint(Theme.violet)
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))

                    Button("CONTINUAR") {
                        dismiss()
                    }
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 12)
                    .padding(.bottom, 20)
                    .buttonStyle(.plain)
                } else {
                    ProgressView()
                        .tint(Theme.accent)
                        .scaleEffect(1.15)
                        .padding(.top, 20)
                        .padding(.bottom, 24)
                }
            }
            .frame(maxWidth: 360)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Theme.accent.opacity(0.70), Theme.violet.opacity(0.48), .white.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: Theme.accent.opacity(0.25), radius: 35, y: 18)
            .padding(.horizontal, 22)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

private struct MoonLoginRedesign: View {
    @ObservedObject var auth: MoonAuthManager
    @State private var key = ""
    @State private var reveal = false
    @FocusState private var focused: Bool

    private var canSubmit: Bool {
        !auth.isChecking && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            MoonAnimatedBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    Spacer(minLength: 42)

                    ZStack {
                        Circle().fill(Theme.accent.opacity(0.20)).frame(width: 130, height: 130).blur(radius: 24)
                        Image(systemName: "moon.stars.fill")
                            .font(.system(size: 52, weight: .black))
                            .foregroundStyle(LinearGradient(colors: [Theme.silver, Theme.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                    .scaleEffect(reveal ? 1 : 0.78)
                    .opacity(reveal ? 1 : 0)

                    ZStack(alignment: .bottomLeading) {
                        RemoteAnimatedGIFView(urlString: MoonRemoteMedia.loginBanner, contentMode: .scaleAspectFill)
                            .frame(height: 205)
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.92)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                        .frame(height: 205)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("MOON X7")
                                .font(.system(size: 28, weight: .black, design: .rounded))
                            Text("PRIVATE CONTROL CENTER")
                                .font(.system(size: 9, weight: .black, design: .rounded))
                                .tracking(2.2)
                                .foregroundStyle(Theme.accent)
                        }
                        .padding(17)
                        .foregroundStyle(.white)
                    }
                    .frame(height: 205)
                    .frame(width: Swift.max(1, UIScreen.main.bounds.width - 40))
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Theme.accent.opacity(0.48), lineWidth: 1) }
                        .shadow(color: Theme.accent.opacity(0.18), radius: 28, y: 12)
                        .padding(.horizontal, 4)

                    VStack(spacing: 6) {
                        Text("MOON X7")
                            .font(.system(size: 38, weight: .black, design: .rounded))
                            .tracking(3.8)
                            .foregroundStyle(.white)
                        Text("PRIVATE CONTROL CENTER")
                            .font(.system(size: 10, weight: .black, design: .rounded))
                            .tracking(2.6)
                            .foregroundStyle(Theme.accent)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("ACCESO SEGURO")
                                .font(.system(size: 10, weight: .black, design: .rounded))
                                .tracking(1.8)
                                .foregroundStyle(.white.opacity(0.42))
                            Text("Introduce tu key para entrar")
                                .font(.system(size: 21, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }

                        HStack(spacing: 10) {
                            Image(systemName: "key.horizontal.fill")
                                .foregroundStyle(Theme.accent)
                            TextField("MOONX7-XXXX-XXXX", text: $key)
                                .focused($focused)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                            Button {
                                key = UIPasteboard.general.string ?? key
                                focused = true
                            } label: {
                                Text("PEGAR")
                                    .font(.system(size: 9, weight: .black, design: .rounded))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 8)
                                    .background(Theme.accent.opacity(0.20), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(14)
                        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 18).stroke(auth.errorMessage == nil ? .white.opacity(0.10) : .red.opacity(0.78), lineWidth: 1) }

                        Button {
                            auth.signIn(key: key)
                        } label: {
                            HStack(spacing: 9) {
                                if auth.isChecking { ProgressView().tint(.white) }
                                Image(systemName: auth.isChecking ? "hourglass" : "arrow.right.circle.fill")
                                Text(auth.isChecking ? "VERIFICANDO..." : "ENTRAR AL PANEL")
                            }
                            .font(.system(size: 14, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                        }
                        .moonGlassButton(prominent: true)
                        .tint(Theme.accent)
                        .disabled(!canSubmit)

                        if let error = auth.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.red.opacity(0.95))
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .padding(18)
                    .moonGlass(cornerRadius: 28, tint: Theme.accent)

                    Text("LICENCIA • DISPOSITIVO • SUPABASE")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(.white.opacity(0.28))
                        .padding(.bottom, 42)
                }
                .padding(.horizontal, 16)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.8).delay(0.05)) { reveal = true }
        }
    }
}

private struct MoonHomeRedesign: View {
    @ObservedObject var auth: MoonAuthManager
    @Binding var tab: Int
    @State private var glow = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MOON X7")
                            .font(.system(size: 31, weight: .black, design: .rounded))
                            .tracking(2.4)
                        Text("CONTROL CENTER")
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .tracking(2)
                            .foregroundStyle(Theme.accent)
                    }
                    Spacer()
                    Button("SALIR") { auth.signOut() }
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13).padding(.vertical, 9)
                        .moonGlassButton()
                }
                .padding(.top, 48)

                RemoteAnimatedGIFView(urlString: MoonRemoteMedia.dashboardBanner, contentMode: .scaleAspectFill)
                    .frame(height: 165)
                    .frame(width: Swift.max(1, UIScreen.main.bounds.width - 30))
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay {
                        LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .center, endPoint: .bottom)
                            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    }
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("NEW REALM")
                                .font(.system(size: 24, weight: .black, design: .rounded))
                            Text("LIQUID GLASS EDITION")
                                .font(.system(size: 9, weight: .black, design: .rounded))
                                .tracking(1.6)
                                .foregroundStyle(Theme.accent)
                        }
                        .padding(17)
                    }
                    .overlay { RoundedRectangle(cornerRadius: 26).stroke(Theme.accent.opacity(0.48), lineWidth: 1) }

                HStack(spacing: 10) {
                    MoonStatCard(icon: "checkmark.shield.fill", title: "LICENCIA", value: "ACTIVA", tint: .green)
                    MoonStatCard(icon: "bolt.fill", title: "MODO", value: "READY", tint: Theme.accent)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("ACCESOS RÁPIDOS")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .tracking(1.7)
                        .foregroundStyle(.white.opacity(0.42))

                    Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { tab = 1 } } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle().fill(Theme.accent.opacity(0.16)).frame(width: 46, height: 46)
                                Image(systemName: "bolt.horizontal.fill").foregroundStyle(Theme.accent)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("FUNCIONES")
                                    .font(.system(size: 15, weight: .black, design: .rounded))
                                Text("FF NORMAL • FF MAX • HOLO")
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.40))
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.35))
                        }
                        .padding(14)
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .moonGlass(cornerRadius: 20, tint: Theme.accent)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("REDES SOCIALES")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .tracking(1.7)
                        .foregroundStyle(.white.opacity(0.42))

                    VStack(spacing: 9) {
                        SocialLinkButton(title: "WhatsApp • Contact Dev", icon: "message.fill", urlString: MoonSocialLinks.whatsapp)
                            .overlay { RGBGlowBorder(cornerRadius: 14, lineWidth: 0.8) }
                        SocialLinkButton(title: "YouTube", icon: "play.rectangle.fill", urlString: MoonSocialLinks.youtube)
                            .overlay { RGBGlowBorder(cornerRadius: 14, lineWidth: 0.8) }
                        SocialLinkButton(title: "Discord", icon: "bubble.left.and.bubble.right.fill", urlString: MoonSocialLinks.discord)
                            .overlay { RGBGlowBorder(cornerRadius: 14, lineWidth: 0.8) }
                        SocialLinkButton(title: "Telegram", icon: "paperplane.fill", urlString: MoonSocialLinks.telegram)
                            .overlay { RGBGlowBorder(cornerRadius: 14, lineWidth: 0.8) }
                        SocialLinkButton(title: "Web", icon: "globe", urlString: MoonSocialLinks.web)
                            .overlay { RGBGlowBorder(cornerRadius: 14, lineWidth: 0.8) }
                    }
                    .padding(13)
                    .moonGlass(cornerRadius: 22, tint: Theme.accent)
                }
            }
            .frame(width: Swift.max(1, UIScreen.main.bounds.width - 30), alignment: .leading)
            .padding(.horizontal, 15)
            .padding(.bottom, 100)
        }
    }
}

private struct MoonStatCard: View {
    let icon: String
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 8, weight: .black, design: .rounded)).foregroundStyle(.white.opacity(0.40))
                Text(value).font(.system(size: 13, weight: .black, design: .rounded)).foregroundStyle(.white)
            }
            Spacer()
        }
        .padding(14)
        .moonGlass(cornerRadius: 19, tint: tint)
    }
}

private struct MoonFunctionsRedesign: View {
    let darkMode: Bool
    @State private var game = 1
    @State private var enabled = Set<String>()
    @State private var filter: MoonOptionFilter = .all

    private let normal: [PatchOption] = [
        PatchOption(id:"r-ffn1", title:"MOON CABEZA", subtitle:"FF NORMAL", patchFile:PatchSlots.ffn1, patchPassword:PatchSlots.password, manualControls:true),
        PatchOption(id:"r-ffn2", title:"MOON CABEZA ATN", subtitle:"FF NORMAL", patchFile:PatchSlots.ffn2, patchPassword:PatchSlots.password, manualControls:true),
        PatchOption(id:"r-ffn3", title:"MOON CUELLO", subtitle:"FF NORMAL", patchFile:PatchSlots.ffn3, patchPassword:PatchSlots.password, manualControls:true),
        PatchOption(id:"r-ffn4", title:"MOON CUELLO ATN", subtitle:"FF NORMAL", patchFile:PatchSlots.ffn4, patchPassword:PatchSlots.password, manualControls:true),
        PatchOption(id:"r-ffn5", title:"MOON DRAG", subtitle:"FF NORMAL", patchFile:PatchSlots.ffn5, patchPassword:PatchSlots.password, manualControls:true),
        PatchOption(id:"r-ffn6", title:"MOON DRAG ATN", subtitle:"FF NORMAL", patchFile:PatchSlots.ffn6, patchPassword:PatchSlots.password, manualControls:true),
        PatchOption(id:"r-ffn7", title:"MOON PECHO", subtitle:"FF NORMAL", patchFile:PatchSlots.ffn7, patchPassword:PatchSlots.password, manualControls:true),
        PatchOption(id:"r-ffn8", title:"MOON PECHO ATN", subtitle:"FF NORMAL", patchFile:PatchSlots.ffn8, patchPassword:PatchSlots.password, manualControls:true),
        PatchOption(id:"r-ffn-fps", title:"120–144 FPS", subtitle:"FF NORMAL • FPS", patchFile:PatchSlots.ffnFPS, patchPassword:PatchSlots.password, manualControls:true),
        PatchOption(id:"r-arm-max-rainbow", title:"ARM HOLO MOON • RAINBOW", subtitle:"FF NORMAL • HOLO ARM", patchFile:"ARM HOLO MOON RAINBOW.3105", patchPassword:PatchSlots.armHoloPassword, manualControls:true, isTexture:true)
    ]

    private let max: [PatchOption] = [
        PatchOption(id:"r-m1", title:"AIM MOON CABEZA", subtitle:"FF MAX • AIM MOON", patchFile:"AIM MOON CABEZA.3105", patchPassword:PatchSlots.password, manualControls:true),
        PatchOption(id:"r-m2", title:"AIM MOON CABEZA ATN", subtitle:"FF MAX • AIM MOON", patchFile:"AIM MOON CABEZA ATN.3105", patchPassword:PatchSlots.password, manualControls:true),
        PatchOption(id:"r-m3", title:"AIM MOON CUELLO", subtitle:"FF MAX • AIM MOON", patchFile:"AIM MOON CUELLO.3105", patchPassword:PatchSlots.password, manualControls:true),
        PatchOption(id:"r-m4", title:"AIM MOON CUELLO ATN", subtitle:"FF MAX • AIM MOON", patchFile:"AIM MOON CUELLO ATN.3105", patchPassword:PatchSlots.password, manualControls:true),
        PatchOption(id:"r-m5", title:"AIM MOON DRAG", subtitle:"FF MAX • AIM MOON", patchFile:"AIM MOON DRAG.3105", patchPassword:PatchSlots.password, manualControls:true),
        PatchOption(id:"r-m6", title:"AIM MOON DRAG ATN", subtitle:"FF MAX • AIM MOON", patchFile:"AIM MOON DRAG ATN.3105", patchPassword:PatchSlots.password, manualControls:true),
        PatchOption(id:"r-m7", title:"AIM MOON PECHO", subtitle:"FF MAX • AIM MOON", patchFile:"AIM MOON PECHO.3105", patchPassword:PatchSlots.password, manualControls:true),
        PatchOption(id:"r-m8", title:"AIM MOON PECHO ATN", subtitle:"FF MAX • AIM MOON", patchFile:"AIM MOON PECHO ATN.3105", patchPassword:PatchSlots.password, manualControls:true),
        PatchOption(id:"r-m-fps", title:"120–144 FPS", subtitle:"FF MAX • FPS", patchFile:PatchSlots.ffmxFPS, patchPassword:PatchSlots.password, manualControls:true),
        PatchOption(id:"r-arm-normal-rainbow", title:"ARM MOON SPIN • RAINBOW", subtitle:"FF MAX • HOLO ARM", patchFile:"ARM MOON SPIN RAINBOW.3105", patchPassword:PatchSlots.armHoloPassword, manualControls:true, isTexture:true),
        PatchOption(id:"r-pj1", title:"PJ HOLO • COTTON CANDY", subtitle:"FF MAX • PJ HOLO", patchFile:"PJ HOLO MOON COTTON CANDY.3105", patchPassword:PatchSlots.pjHoloPassword, manualControls:true, isTexture:true),
        PatchOption(id:"r-pj2", title:"PJ HOLO • DARK GALAXY", subtitle:"FF MAX • PJ HOLO", patchFile:"PJ HOLO MOON DARK GALAXY.3105", patchPassword:PatchSlots.pjHoloPassword, manualControls:true, isTexture:true),
        PatchOption(id:"r-pj3", title:"PJ HOLO • ESPEJOS", subtitle:"FF MAX • PJ HOLO", patchFile:"PJ HOLO MOON ESPEJOS.3105", patchPassword:PatchSlots.pjHoloPassword, manualControls:true, isTexture:true)
    ]

    private var allOptions: [PatchOption] { game == 0 ? normal : max }

    private var options: [PatchOption] {
        switch filter {
        case .all:
            return allOptions
        case .holos:
            return allOptions.filter { $0.isTexture }
        case .aim:
            return allOptions.filter {
                !$0.isTexture &&
                $0.title.localizedCaseInsensitiveContains("AIM")
            }
        case .moons:
            return allOptions.filter {
                !$0.isTexture &&
                !$0.title.localizedCaseInsensitiveContains("AIM") &&
                !$0.title.localizedCaseInsensitiveContains("ATN") &&
                $0.title.localizedCaseInsensitiveContains("MOON")
            }
        case .atn:
            return allOptions.filter {
                !$0.isTexture &&
                $0.title.localizedCaseInsensitiveContains("ATN")
            }
        }
    }

    var body: some View {
        ScrollView(showsIndicators:false) {
            VStack(alignment:.leading, spacing:15) {
                HStack {
                    VStack(alignment:.leading, spacing:4) {
                        Text("FUNCIONES")
                            .font(.system(size:30, weight:.black, design:.rounded))
                        Text(game == 0 ? "FREE FIRE NORMAL" : "FREE FIRE MAX")
                            .font(.system(size:9, weight:.black, design:.rounded))
                            .tracking(1.7)
                            .foregroundStyle(Theme.accent)
                    }
                    Spacer()
                    Text("\(allOptions.count) OPCIONES")
                        .font(.system(size:9, weight:.black, design:.rounded))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .padding(.top,48)

                ZStack(alignment:.bottomLeading) {
                    RemoteAnimatedGIFView(urlString: MoonRemoteMedia.dashboardBanner, contentMode:.scaleAspectFill)
                        .frame(height:165)
                        .frame(maxWidth:.infinity)
                        .clipShape(RoundedRectangle(cornerRadius:24, style:.continuous))

                    LinearGradient(
                        colors:[.clear,.black.opacity(0.86)],
                        startPoint:.center,
                        endPoint:.bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius:24, style:.continuous))

                    VStack(alignment:.leading, spacing:4) {
                        Text("MOON X7")
                            .font(.system(size:23, weight:.black, design:.rounded))
                        Text("LIQUID GLASS • CONTROL CENTER")
                            .font(.system(size:9, weight:.black, design:.rounded))
                            .tracking(1.5)
                            .foregroundStyle(Theme.accent)
                    }
                    .padding(15)
                    .foregroundStyle(.white)
                }
                .overlay {
                    RoundedRectangle(cornerRadius:24, style:.continuous)
                        .stroke(
                            LinearGradient(
                                colors:[Theme.accent.opacity(0.72),Theme.violet.opacity(0.45),.white.opacity(0.08)],
                                startPoint:.topLeading,
                                endPoint:.bottomTrailing
                            ),
                            lineWidth:1.2
                        )
                }

                HStack(spacing:8) {
                    MoonSegment(title:"FREE FIRE", selected:game == 0) {
                        withAnimation(.spring(response:0.35,dampingFraction:0.82)) {
                            game = 0
                            filter = .all
                        }
                    }
                    MoonSegment(title:"FREE FIRE MAX", selected:game == 1) {
                        withAnimation(.spring(response:0.35,dampingFraction:0.82)) {
                            game = 1
                            filter = .all
                        }
                    }
                }

                HStack(spacing:7) {
                    filterCard(.all, title:"VER TODOS", value:allOptions.count, icon:"square.grid.2x2.fill", tint:.white)
                    filterCard(.holos, title:"HOLOS", value:allOptions.filter { $0.isTexture }.count, icon:"sparkles", tint:Theme.violet)
                    filterCard(.aim, title:"AIM", value:allOptions.filter { !$0.isTexture && $0.title.localizedCaseInsensitiveContains("AIM") }.count, icon:"scope", tint:Theme.accent)
                    filterCard(.moons, title:"MOONS", value:allOptions.filter { !$0.isTexture && !$0.title.localizedCaseInsensitiveContains("AIM") && !$0.title.localizedCaseInsensitiveContains("ATN") && $0.title.localizedCaseInsensitiveContains("MOON") }.count, icon:"circle.grid.3x3.fill", tint:.white)
                    filterCard(.atn, title:"ATN", value:allOptions.filter { !$0.isTexture && $0.title.localizedCaseInsensitiveContains("ATN") }.count, icon:"target", tint:Theme.accent)
                }

                HStack {
                    Text(filter.label)
                        .font(.system(size:9, weight:.black, design:.rounded))
                        .tracking(1.4)
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    Text("\(options.count) MOSTRANDO")
                        .font(.system(size:8.5, weight:.black, design:.rounded))
                        .foregroundStyle(.white.opacity(0.34))
                }
                .padding(.top,4)

                ForEach(options) { option in
                    MoonPatchRedesignCard(option: option, enabled: $enabled)
                }
            }
            .frame(width:Swift.max(1,UIScreen.main.bounds.width - 30), alignment:.leading)
            .padding(.horizontal,15)
            .padding(.bottom,105)
        }
    }

    private func filterCard(_ filterValue: MoonOptionFilter, title:String, value:Int, icon:String, tint:Color) -> some View {
        Button {
            withAnimation(.spring(response:0.30,dampingFraction:0.84)) { filter = filterValue }
        } label: {
            VStack(alignment:.leading, spacing:4) {
                Image(systemName:icon)
                    .font(.system(size:11, weight:.black))
                    .foregroundStyle(tint)
                Text("\(value)")
                    .font(.system(size:17, weight:.black, design:.rounded))
                Text(title)
                    .font(.system(size:6.8, weight:.black, design:.rounded))
                    .tracking(0.45)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .foregroundStyle(.white.opacity(0.40))
            }
            .frame(maxWidth:.infinity, alignment:.leading)
            .padding(9)
            .foregroundStyle(.white)
            .background(filter == filterValue ? tint.opacity(0.16) : .clear, in:RoundedRectangle(cornerRadius:15,style:.continuous))
            .overlay {
                RoundedRectangle(cornerRadius:15,style:.continuous)
                    .stroke(filter == filterValue ? tint.opacity(0.65) : .white.opacity(0.08), lineWidth:1)
            }
        }
        .buttonStyle(.plain)
    }
}

private enum MoonOptionFilter {
    case all, holos, aim, moons, atn

    var label: String {
        switch self {
        case .all: return "VER TODOS"
        case .holos: return "HOLOS"
        case .aim: return "AIM"
        case .moons: return "MOONS"
        case .atn: return "ATN"
        }
    }
}

private struct MoonSummaryCard: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 18, weight: .black, design: .rounded))
            Text(title)
                .font(.system(size: 7.5, weight: .black, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(.white.opacity(0.38))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .foregroundStyle(.white)
        .moonGlass(cornerRadius: 16, tint: tint)
    }
}
private struct MoonSegment: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action:action) {
            Text(title)
                .font(.system(size:11.5, weight:.black, design:.rounded))
                .foregroundStyle(selected ? .white : .white.opacity(0.42))
                .frame(maxWidth:.infinity).frame(height:50)
        }
        .buttonStyle(.plain)
        .background(selected ? Theme.accent.opacity(0.22) : .white.opacity(0.035), in: RoundedRectangle(cornerRadius:16, style:.continuous))
        .overlay { RoundedRectangle(cornerRadius:16).stroke(selected ? Theme.accent.opacity(0.55) : .white.opacity(0.08), lineWidth:1) }
        .animation(.easeInOut(duration:0.2), value:selected)
    }
}

private struct MoonPatchRedesignCard: View {
    let option: PatchOption
    @Binding var enabled: Set<String>
    @State private var busy = false
    @State private var expanded = false
    @State private var error: String?
    @State private var successMessage: String?

    private var active: Bool { enabled.contains(option.id) }
    private var holo: Bool { option.isTexture }

    var body: some View {
        VStack(spacing:0) {
            Button {
                withAnimation(.spring(response:0.34,dampingFraction:0.82)) { expanded.toggle() }
            } label: {
                HStack(spacing:13) {
                    ZStack {
                        RoundedRectangle(cornerRadius:15).fill(holo ? Theme.violet.opacity(0.18) : Theme.accent.opacity(0.13))
                        Image(systemName: holo ? "sparkles" : "scope")
                            .font(.system(size:18, weight:.bold))
                            .foregroundStyle(holo ? Theme.violet : Theme.accent)
                    }
                    .frame(width:48,height:48)

                    VStack(alignment:.leading, spacing:4) {
                        Text(option.title)
                            .font(.system(size:14.5, weight:.black, design:.rounded))
                            .foregroundStyle(.white).multilineTextAlignment(.leading)
                        Text(option.subtitle ?? "")
                            .font(.system(size:9, weight:.black, design:.rounded))
                            .tracking(1.1).foregroundStyle(.white.opacity(0.38))
                    }
                    Spacer()
                    if busy { ProgressView().tint(.white) }
                    Circle()
                        .stroke(active ? Theme.accent : .white.opacity(0.16), lineWidth:1.4)
                        .frame(width:23,height:23)
                        .overlay {
                            if active { Circle().fill(Theme.accent).frame(width:11,height:11) }
                        }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size:10, weight:.black))
                        .foregroundStyle(.white.opacity(0.38))
                }
                .padding(14)
            }
            .buttonStyle(.plain)

            if expanded {
                HStack(spacing:9) {
                    MoonActionButton(title: holo ? "INJETAR" : "INJETAR 40%", icon:"bolt.fill", tint:Theme.accent, disabled:busy) {
                        run(apply:true)
                    }
                    MoonActionButton(title: holo ? "QUITAR" : "QUITAR LOBBY", icon:"arrow.uturn.backward", tint:Theme.violet, disabled:busy) {
                        run(apply:false)
                    }
                }
                .padding(.horizontal,14).padding(.bottom,14)
                .transition(.asymmetric(insertion:.scale(scale:0.96).combined(with:.opacity), removal:.opacity))
            }
        }
        .foregroundStyle(.white)
        .moonGlass(cornerRadius:21, tint:holo ? Theme.violet : Theme.accent)
        .overlay {
            RoundedRectangle(cornerRadius:21).stroke(
                LinearGradient(colors:[active ? Theme.accent.opacity(0.78) : .white.opacity(0.08), holo ? Theme.violet.opacity(0.38) : .clear], startPoint:.leading, endPoint:.trailing),
                lineWidth: active ? 1.2 : 0.8
            )
        }
        .alert("MOON X7", isPresented: Binding(get:{error != nil}, set:{if !$0{error=nil}})) {
            Button("OK") { error=nil }
        } message: { Text(error ?? "") }
        .alert("MOONCONFIG", isPresented: Binding(get: { successMessage != nil }, set: { if !$0 { successMessage = nil } })) {
            Button("OK") { successMessage = nil }
        } message: {
            Text(successMessage ?? "")
        }
    }

    private func run(apply: Bool) {
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos:.userInitiated).async {
            let result = PatchSlotRunner.setEnabled(apply, slotID: option.id, fileName: option.patchFile, configuredPassword: option.patchPassword)
            DispatchQueue.main.async {
                busy = false
                switch result {
                case .success:
                    if apply { enabled.insert(option.id) } else { enabled.remove(option.id) }
                    successMessage = apply ? "moonconfig apply" : "moonconfig org restore"
                case .failure(let err):
                    error = PatchSlotRunner.message(for: err)
                }
            }
        }
    }
}

private struct MoonActionButton: View {
    let title: String
    let icon: String
    let tint: Color
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action:action) {
            Label(title, systemImage:icon)
                .font(.system(size:11, weight:.black, design:.rounded))
                .foregroundStyle(.white)
                .frame(maxWidth:.infinity).frame(height:44)
        }
        .moonGlassButton()
        .tint(tint)
        .disabled(disabled)
    }
}

private struct MoonPreviewRedesign: View {
    private let items = [
        ("ARM HOLO MOON • RAINBOW", "ARM HOLO MOON RAINBOW.mp4"),
        ("ARM MOON SPIN • RAINBOW", "ARM MOON SPIN RAINBOW.mp4"),
        ("PJ HOLO MOON COTTON CANDY", "PJ HOLO MOON COTTON CANDY.mp4"),
        ("PJ HOLO MOON DARK GALAXY", "PJ HOLO MOON DARK GALAXY.mp4"),
        ("PJ HOLO MOON ESPEJOS", "PJ HOLO MOON ESPEJOS.mp4")
    ]
    @State private var selected: String?

    var body: some View {
        ScrollView(showsIndicators:false) {
            VStack(alignment:.leading, spacing:15) {
                VStack(alignment:.leading, spacing:5) {
                    Text("PREVIEW").font(.system(size:31, weight:.black, design:.rounded))
                    Text("HOLO COLLECTION").font(.system(size:9, weight:.black, design:.rounded)).tracking(1.8).foregroundStyle(Theme.accent)
                }
                .padding(.top,48)

                ForEach(items, id:\.0) { item in
                    VStack(spacing:0) {
                        Button {
                            withAnimation(.spring(response:0.35,dampingFraction:0.82)) {
                                selected = selected == item.0 ? nil : item.0
                            }
                        } label: {
                            HStack {
                                Image(systemName:"play.circle.fill").font(.system(size:28)).foregroundStyle(Theme.accent)
                                VStack(alignment:.leading, spacing:3) {
                                    Text(item.0).font(.system(size:13.5, weight:.black, design:.rounded))
                                    Text(item.1).font(.system(size:8.5, weight:.medium, design:.monospaced)).foregroundStyle(.white.opacity(0.32))
                                }
                                Spacer()
                                Image(systemName:selected == item.0 ? "chevron.up" : "chevron.down").foregroundStyle(.white.opacity(0.35))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if selected == item.0 {
                            if let root = Bundle.main.resourceURL {
                                let url = root.appendingPathComponent("PreviewImages", isDirectory:true).appendingPathComponent(item.1)
                                if FileManager.default.fileExists(atPath:url.path) {
                                    CleanVideoPlayer(url: url)
                                        .frame(height:230)
                                        .clipShape(RoundedRectangle(cornerRadius:16, style:.continuous))
                                        .padding(.horizontal,12).padding(.bottom,12)
                                } else {
                                    Text("Preview no disponible en el bundle.")
                                        .font(.system(size:10, weight:.semibold))
                                        .foregroundStyle(.white.opacity(0.35))
                                        .padding(.bottom,14)
                                }
                            }
                        }
                    }
                    .moonGlass(cornerRadius:20, tint:Theme.accent)
                }
            }
            .padding(.horizontal,15).padding(.bottom,105)
        }
    }
}

private struct MoonConfigRedesign: View {
    @ObservedObject var auth: MoonAuthManager

    var body: some View {
        ScrollView(showsIndicators:false) {
            VStack(alignment:.leading, spacing:15) {
                Text("CONFIG").font(.system(size:31, weight:.black, design:.rounded)).padding(.top,48)
                Text("LICENCIA • DISPOSITIVO • SESIÓN")
                    .font(.system(size:9, weight:.black, design:.rounded))
                    .tracking(1.7).foregroundStyle(Theme.accent)

                VStack(alignment:.leading, spacing:12) {
                    configLine("ESTADO", auth.isAuthenticated ? "ACTIVA" : "SIN SESIÓN", color:.green)
                    configLine("KEY", auth.licenseKey ?? "—")
                    configLine("PLAN", auth.plan?.uppercased() ?? "—")
                    configLine("DÍAS", auth.durationDays.map(String.init) ?? "—")
                    configLine("ACTIVADA", auth.activatedAt.map { $0.formatted(date:.abbreviated, time:.shortened) } ?? "—")
                    configLine("EXPIRA", auth.expiresAt.map { $0.formatted(date:.abbreviated, time:.shortened) } ?? "—")
                }
                .padding(17)
                .moonGlass(cornerRadius:24, tint:Theme.accent)

                VStack(alignment:.leading, spacing:10) {
                    Text("DISPOSITIVO")
                        .font(.system(size:9, weight:.black, design:.rounded))
                        .tracking(1.6).foregroundStyle(.white.opacity(0.38))
                    configLine("MODELO", DeviceInfo.machine)
                    configLine("IOS", UIDevice.current.systemVersion)
                    configLine("BUILD", "2.2.0")
                }
                .padding(17)
                .moonGlass(cornerRadius:24, tint:Theme.violet)

                Button("CERRAR SESIÓN") { auth.signOut() }
                    .font(.system(size:12, weight:.black, design:.rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth:.infinity).frame(height:50)
                    .moonGlassButton(prominent: true)
                    .tint(Theme.accent)
            }
            .padding(.horizontal,15).padding(.bottom,105)
        }
    }

    private func configLine(_ title:String, _ value:String, color:Color = .white) -> some View {
        HStack {
            Text(title).font(.system(size:8.5, weight:.black, design:.rounded)).tracking(1).foregroundStyle(.white.opacity(0.34))
            Spacer(minLength:12)
            Text(value).font(.system(size:11, weight:.bold, design:.monospaced)).foregroundStyle(color).multilineTextAlignment(.trailing)
        }
    }
}


// ============================================================
// MARK: - MOONX7 REDESIGN V2
// ============================================================

private enum MoonX7V2Palette {
    static let red = Color(red: 0.82, green: 0.035, blue: 0.10)
    static let redBright = Color(red: 1.0, green: 0.10, blue: 0.18)
    static let purple = Color(red: 0.42, green: 0.08, blue: 0.72)
    static let purpleBright = Color(red: 0.64, green: 0.18, blue: 0.95)
    static let silver = Color(red: 0.91, green: 0.92, blue: 0.96)
    static let charcoal = Color(red: 0.055, green: 0.055, blue: 0.065)
}

private struct MoonX7V2Shell: View {
    @ObservedObject var auth: MoonAuthManager
    @Binding var darkMode: Bool
    @State private var tab = 0

    private let tabs: [(String, String)] = [
        ("house.fill", "HOME"),
        ("gamecontroller.fill", "GAMES"),
        ("play.rectangle.fill", "PREVIEW"),
        ("gearshape.fill", "CONFIG")
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            MoonX7V2Background()

            Group {
                switch tab {
                case 0:
                    MoonX7V2HomeView(auth: auth, tab: $tab)
                case 1:
                    MoonX7V2GamesView()
                case 2:
                    MoonPreviewRedesign()
                default:
                    MoonX7V2ConfigView(auth: auth)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: 74)
            }

            MoonX7V2TabBar(selection: $tab, tabs: tabs)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
        }
        .preferredColorScheme(.dark)
    }
}

private struct MoonX7V2Background: View {
    @State private var drift = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            RadialGradient(
                colors: [
                    MoonX7V2Palette.purple.opacity(0.16),
                    .clear
                ],
                center: drift ? .topTrailing : .topLeading,
                startRadius: 10,
                endRadius: 430
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [
                    MoonX7V2Palette.red.opacity(0.11),
                    .clear
                ],
                center: drift ? .bottomLeading : .bottomTrailing,
                startRadius: 20,
                endRadius: 380
            )
            .ignoresSafeArea()

            LinearGradient(
                colors: [
                    Color.white.opacity(0.018),
                    .clear,
                    MoonX7V2Palette.purple.opacity(0.025)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 8).repeatForever(autoreverses: true)) {
                drift.toggle()
            }
        }
    }
}

private struct MoonX7V2Logo: View {
    var width: CGFloat = 190
    var body: some View {
        VStack(spacing: 7) {
            // The app keeps its existing asset fallback so the redesign never depends
            // on a remote image or a new runtime download.
            Image("MOONX7Mark")
                .resizable()
                .scaledToFit()
                .frame(width: width, height: width * 0.58)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .shadow(color: MoonX7V2Palette.purple.opacity(0.28), radius: 20, y: 7)
        .accessibilityLabel("MOONX7")
    }
}

private struct MoonX7V2GlassCard<Content: View>: View {
    let tint: Color
    let content: Content

    init(tint: Color = MoonX7V2Palette.purple, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(0.045))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                tint.opacity(0.52),
                                .white.opacity(0.08),
                                MoonX7V2Palette.red.opacity(0.18)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: tint.opacity(0.08), radius: 22, y: 10)
    }
}

private struct MoonX7V2TabBar: View {
    @Binding var selection: Int
    let tabs: [(String, String)]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                Button {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
                        selection = index
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.0)
                            .font(.system(size: 15, weight: .bold))
                        Text(tab.1)
                            .font(.system(size: 8, weight: .black, design: .rounded))
                            .tracking(0.5)
                    }
                    .foregroundStyle(selection == index ? .white : .white.opacity(0.38))
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background {
                        if selection == index {
                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            MoonX7V2Palette.red.opacity(0.28),
                                            MoonX7V2Palette.purple.opacity(0.20)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .overlay {
                                    Capsule(style: .continuous)
                                        .stroke(MoonX7V2Palette.red.opacity(0.42), lineWidth: 1)
                                }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(7)
        .background(.black.opacity(0.72), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(.white.opacity(0.09), lineWidth: 1)
        }
        .shadow(color: MoonX7V2Palette.purple.opacity(0.18), radius: 24, y: 9)
    }
}

private struct MoonX7V2LoginView: View {
    @ObservedObject var auth: MoonAuthManager
    @State private var key = ""
    @State private var appeared = false
    @FocusState private var focused: Bool

    private var canSubmit: Bool {
        !auth.isChecking &&
        !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            MoonX7V2Background()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    Spacer(minLength: 36)

                    MoonX7V2Logo(width: 230)
                        .scaleEffect(appeared ? 1 : 0.90)
                        .opacity(appeared ? 1 : 0)

                    VStack(spacing: 6) {
                        Text("PRIVATE CONTROL CENTER")
                            .font(.system(size: 10, weight: .black, design: .rounded))
                            .tracking(2.8)
                            .foregroundStyle(MoonX7V2Palette.redBright)

                        Text("SECURE ACCESS")
                            .font(.system(size: 23, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                    }

                    MoonX7V2GlassCard(tint: MoonX7V2Palette.purple) {
                        VStack(alignment: .leading, spacing: 15) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("LICENCIA")
                                    .font(.system(size: 9, weight: .black, design: .rounded))
                                    .tracking(1.8)
                                    .foregroundStyle(.white.opacity(0.38))

                                Text("Introduce tu key MOONX7")
                                    .font(.system(size: 20, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                            }

                            HStack(spacing: 10) {
                                Image(systemName: "key.horizontal.fill")
                                    .foregroundStyle(MoonX7V2Palette.silver)

                                TextField("MOONX7-XXXX-XXXX", text: $key)
                                    .focused($focused)
                                    .textInputAutocapitalization(.characters)
                                    .autocorrectionDisabled()
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white)

                                Button("PEGAR") {
                                    key = UIPasteboard.general.string ?? key
                                    focused = true
                                }
                                .font(.system(size: 8.5, weight: .black, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(MoonX7V2Palette.red.opacity(0.18), in: Capsule())
                                .buttonStyle(.plain)
                            }
                            .padding(13)
                            .background(Color.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 17, style: .continuous)
                                    .stroke(auth.errorMessage == nil ? .white.opacity(0.08) : .red.opacity(0.72), lineWidth: 1)
                            }

                            Button {
                                auth.signIn(key: key)
                            } label: {
                                HStack(spacing: 9) {
                                    if auth.isChecking {
                                        ProgressView().tint(.white)
                                    }
                                    Image(systemName: auth.isChecking ? "hourglass" : "arrow.right.circle.fill")
                                    Text(auth.isChecking ? "VERIFICANDO..." : "ENTRAR")
                                }
                                .font(.system(size: 13, weight: .black, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                            }
                            .background(
                                LinearGradient(
                                    colors: [
                                        MoonX7V2Palette.red.opacity(canSubmit ? 0.92 : 0.32),
                                        MoonX7V2Palette.purple.opacity(canSubmit ? 0.72 : 0.30)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 17, style: .continuous)
                                    .stroke(.white.opacity(canSubmit ? 0.16 : 0.05), lineWidth: 1)
                            }
                            .disabled(!canSubmit)

                            if let error = auth.errorMessage {
                                Label(error, systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(.red.opacity(0.95))
                            }
                        }
                        .padding(18)
                    }

                    Text("LICENSE • DEVICE • SUPABASE")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .tracking(1.3)
                        .foregroundStyle(.white.opacity(0.22))
                        .padding(.bottom, 38)
                }
                .padding(.horizontal, 16)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.70, dampingFraction: 0.82)) {
                appeared = true
            }
        }
    }
}

private struct MoonX7V2HomeView: View {
    @ObservedObject var auth: MoonAuthManager
    @Binding var tab: Int
    @State private var pulse = false

    private var maskedKey: String {
        guard let key = auth.licenseKey, key.count > 8 else { return auth.licenseKey ?? "—" }
        return String(key.prefix(4)) + "••••••••" + String(key.suffix(4))
    }

    private var remainingText: String {
        guard let expires = auth.expiresAt else { return "—" }
        let seconds = max(0, Int(expires.timeIntervalSinceNow))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    MoonX7V2Logo(width: 116)
                    Spacer()
                    Button {
                        auth.signOut()
                    } label: {
                        Label("SALIR", systemImage: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11)
                            .frame(height: 36)
                    }
                    .background(.white.opacity(0.055), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 1))
                    .buttonStyle(.plain)
                }
                .padding(.top, 26)

                VStack(alignment: .leading, spacing: 5) {
                    Text("WELCOME BACK")
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .tracking(2.1)
                        .foregroundStyle(MoonX7V2Palette.redBright)

                    Text("MOONX7 CONTROL")
                        .font(.system(size: 29, weight: .black, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Tu sesión está protegida y lista.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.42))
                }

                MoonX7V2GlassCard(tint: MoonX7V2Palette.red) {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color.green.opacity(0.13))
                                .frame(width: 52, height: 52)
                            Circle()
                                .stroke(Color.green.opacity(0.42), lineWidth: 1)
                                .frame(width: 52, height: 52)
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                                .scaleEffect(pulse ? 1.35 : 0.9)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("SESSION STATUS")
                                .font(.system(size: 8.5, weight: .black, design: .rounded))
                                .tracking(1.5)
                                .foregroundStyle(.white.opacity(0.36))
                            Text("ACTIVE")
                                .font(.system(size: 18, weight: .black, design: .rounded))
                                .foregroundStyle(.white)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 4) {
                            Text("REMAINING")
                                .font(.system(size: 8, weight: .black, design: .rounded))
                                .foregroundStyle(.white.opacity(0.30))
                            Text(remainingText)
                                .font(.system(size: 16, weight: .black, design: .rounded))
                                .foregroundStyle(MoonX7V2Palette.silver)
                        }
                    }
                    .padding(17)
                }

                MoonX7V2GlassCard(tint: MoonX7V2Palette.purple) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("ACCOUNT")
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .tracking(1.8)
                            .foregroundStyle(MoonX7V2Palette.purpleBright)

                        HStack {
                            Text("KEY")
                                .foregroundStyle(.white.opacity(0.36))
                            Spacer()
                            Text(maskedKey)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                        }

                        HStack {
                            Text("PLAN")
                                .foregroundStyle(.white.opacity(0.36))
                            Spacer()
                            Text(auth.plan?.uppercased() ?? "—")
                                .font(.system(size: 11, weight: .black, design: .rounded))
                                .foregroundStyle(.white)
                        }

                        if let expires = auth.expiresAt {
                            HStack {
                                Text("EXPIRES")
                                    .foregroundStyle(.white.opacity(0.36))
                                Spacer()
                                Text(expires.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.78))
                            }
                        }
                    }
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .padding(17)
                }

                Text("GAMES")
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .tracking(1.8)
                    .foregroundStyle(.white.opacity(0.34))

                HStack(spacing: 10) {
                    MoonX7V2GameShortcut(
                        title: "FF NORMAL",
                        subtitle: "MOON • HOLOS • FPS",
                        icon: "gamecontroller.fill",
                        tint: MoonX7V2Palette.silver
                    ) {
                        tab = 1
                    }

                    MoonX7V2GameShortcut(
                        title: "FF MAX",
                        subtitle: "AIM • HOLOS • FPS",
                        icon: "bolt.fill",
                        tint: MoonX7V2Palette.redBright
                    ) {
                        tab = 1
                    }
                }

                MoonX7V2GlassCard(tint: MoonX7V2Palette.red) {
                    Button {
                        tab = 3
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 19, weight: .bold))
                                .foregroundStyle(MoonX7V2Palette.silver)
                                .frame(width: 40, height: 40)
                                .background(MoonX7V2Palette.purple.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                            VStack(alignment: .leading, spacing: 3) {
                                Text("CONFIG")
                                    .font(.system(size: 13, weight: .black, design: .rounded))
                                    .foregroundStyle(.white)
                                Text("Cuenta, dispositivo y sesión")
                                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.36))
                            }

                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.white.opacity(0.30))
                        }
                        .padding(15)
                    }
                    .buttonStyle(.plain)
                }

                Text("MOONX7 • SECURE SESSION")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.18))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
                    .padding(.bottom, 18)
            }
            .padding(.horizontal, 15)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

private struct MoonX7V2GameShortcut: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .black))
                    .foregroundStyle(tint)

                Text(title)
                    .font(.system(size: 14, weight: .black, design: .rounded))
                    .foregroundStyle(.white)

                Text(subtitle)
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(0.34))
                    .lineLimit(2)

                Spacer(minLength: 2)

                HStack {
                    Text("ABRIR")
                        .font(.system(size: 8.5, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.58))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(tint)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 142, alignment: .leading)
            .padding(15)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(tint.opacity(0.22), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct MoonX7V2GamesView: View {
    @State private var game = 1
    @State private var filter: MoonOptionFilter = .all
    @State private var enabled = Set<String>()
    @State private var search = ""

    private let normal: [PatchOption] = [
        PatchOption(id: "r-ffn1", title: "MOON CABEZA", subtitle: "FF NORMAL", patchFile: PatchSlots.ffn1, patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "r-ffn2", title: "MOON CABEZA ATN", subtitle: "FF NORMAL", patchFile: PatchSlots.ffn2, patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "r-ffn3", title: "MOON CUELLO", subtitle: "FF NORMAL", patchFile: PatchSlots.ffn3, patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "r-ffn4", title: "MOON CUELLO ATN", subtitle: "FF NORMAL", patchFile: PatchSlots.ffn4, patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "r-ffn5", title: "MOON DRAG", subtitle: "FF NORMAL", patchFile: PatchSlots.ffn5, patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "r-ffn6", title: "MOON DRAG ATN", subtitle: "FF NORMAL", patchFile: PatchSlots.ffn6, patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "r-ffn7", title: "MOON PECHO", subtitle: "FF NORMAL", patchFile: PatchSlots.ffn7, patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "r-ffn8", title: "MOON PECHO ATN", subtitle: "FF NORMAL", patchFile: PatchSlots.ffn8, patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "r-ffn-fps", title: "120–144 FPS", subtitle: "FF NORMAL • FPS", patchFile: PatchSlots.ffnFPS, patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "r-arm-max-rainbow", title: "ARM HOLO MOON • RAINBOW", subtitle: "FF NORMAL • HOLO ARM", patchFile: "ARM HOLO MOON RAINBOW.3105", patchPassword: PatchSlots.armHoloPassword, manualControls: true, isTexture: true)
    ]

    private let max: [PatchOption] = [
        PatchOption(id: "r-m1", title: "AIM MOON CABEZA", subtitle: "FF MAX • AIM MOON", patchFile: "AIM MOON CABEZA.3105", patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "r-m2", title: "AIM MOON CABEZA ATN", subtitle: "FF MAX • AIM MOON", patchFile: "AIM MOON CABEZA ATN.3105", patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "r-m3", title: "AIM MOON CUELLO", subtitle: "FF MAX • AIM MOON", patchFile: "AIM MOON CUELLO.3105", patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "r-m4", title: "AIM MOON CUELLO ATN", subtitle: "FF MAX • AIM MOON", patchFile: "AIM MOON CUELLO ATN.3105", patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "r-m5", title: "AIM MOON DRAG", subtitle: "FF MAX • AIM MOON", patchFile: "AIM MOON DRAG.3105", patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "r-m6", title: "AIM MOON DRAG ATN", subtitle: "FF MAX • AIM MOON", patchFile: "AIM MOON DRAG ATN.3105", patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "r-m7", title: "AIM MOON PECHO", subtitle: "FF MAX • AIM MOON", patchFile: "AIM MOON PECHO.3105", patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "r-m8", title: "AIM MOON PECHO ATN", subtitle: "FF MAX • AIM MOON", patchFile: "AIM MOON PECHO ATN.3105", patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "r-m-fps", title: "120–144 FPS", subtitle: "FF MAX • FPS", patchFile: PatchSlots.ffmxFPS, patchPassword: PatchSlots.password, manualControls: true),
        PatchOption(id: "r-arm-normal-rainbow", title: "ARM MOON SPIN • RAINBOW", subtitle: "FF MAX • HOLO ARM", patchFile: "ARM MOON SPIN RAINBOW.3105", patchPassword: PatchSlots.armHoloPassword, manualControls: true, isTexture: true),
        PatchOption(id: "r-pj1", title: "PJ HOLO • COTTON CANDY", subtitle: "FF MAX • PJ HOLO", patchFile: "PJ HOLO MOON COTTON CANDY.3105", patchPassword: PatchSlots.pjHoloPassword, manualControls: true, isTexture: true),
        PatchOption(id: "r-pj2", title: "PJ HOLO • DARK GALAXY", subtitle: "FF MAX • PJ HOLO", patchFile: "PJ HOLO MOON DARK GALAXY.3105", patchPassword: PatchSlots.pjHoloPassword, manualControls: true, isTexture: true),
        PatchOption(id: "r-pj3", title: "PJ HOLO • ESPEJOS", subtitle: "FF MAX • PJ HOLO", patchFile: "PJ HOLO MOON ESPEJOS.3105", patchPassword: PatchSlots.pjHoloPassword, manualControls: true, isTexture: true)
    ]

    private var allOptions: [PatchOption] { game == 0 ? normal : max }

    private var filteredOptions: [PatchOption] {
        let base: [PatchOption]
        switch filter {
        case .all:
            base = allOptions
        case .holos:
            base = allOptions.filter { $0.isTexture }
        case .aim:
            base = allOptions.filter { !$0.isTexture && $0.title.localizedCaseInsensitiveContains("AIM") }
        case .moons:
            base = allOptions.filter {
                !$0.isTexture &&
                !$0.title.localizedCaseInsensitiveContains("AIM") &&
                !$0.title.localizedCaseInsensitiveContains("ATN") &&
                $0.title.localizedCaseInsensitiveContains("MOON")
            }
        case .atn:
            base = allOptions.filter { !$0.isTexture && $0.title.localizedCaseInsensitiveContains("ATN") }
        }
        guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return base }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(search) ||
            ($0.subtitle ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("GAMES")
                            .font(.system(size: 30, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                        Text(game == 0 ? "FREE FIRE NORMAL" : "FREE FIRE MAX")
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .tracking(1.7)
                            .foregroundStyle(MoonX7V2Palette.redBright)
                    }
                    Spacer()
                    Text("\(allOptions.count)")
                        .font(.system(size: 23, weight: .black, design: .rounded))
                        .foregroundStyle(MoonX7V2Palette.silver)
                }
                .padding(.top, 26)

                HStack(spacing: 8) {
                    MoonX7V2GameModeButton(title: "FF NORMAL", selected: game == 0) {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            game = 0
                            filter = .all
                        }
                    }
                    MoonX7V2GameModeButton(title: "FF MAX", selected: game == 1) {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            game = 1
                            filter = .all
                        }
                    }
                }

                HStack(spacing: 8) {
                    MoonX7V2FilterButton(title: "VER TODOS", selected: filter == .all) { filter = .all }
                    MoonX7V2FilterButton(title: "HOLOS", selected: filter == .holos) { filter = .holos }
                    MoonX7V2FilterButton(title: "AIM", selected: filter == .aim) { filter = .aim }
                    MoonX7V2FilterButton(title: "MOONS", selected: filter == .moons) { filter = .moons }
                    MoonX7V2FilterButton(title: "ATN", selected: filter == .atn) { filter = .atn }
                }

                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.white.opacity(0.34))
                    TextField("Buscar opción", text: $search)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(.white)
                    if !search.isEmpty {
                        Button {
                            search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white.opacity(0.30))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .padding(.horizontal, 13)
                .frame(height: 43)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                }

                Text("\(filteredOptions.count) OPCIONES")
                    .font(.system(size: 8.5, weight: .black, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.28))
                    .padding(.top, 2)

                ForEach(filteredOptions) { option in
                    MoonX7V2PatchCard(option: option, enabled: $enabled)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.97)),
                            removal: .opacity
                        ))
                }

                Spacer(minLength: 95)
            }
            .padding(.horizontal, 15)
        }
        .onAppear {
            syncActiveReceipts()
        }
    }

    private func syncActiveReceipts() {
        var current = Set<String>()
        for option in normal + max {
            if ActivePatchReceipts.load(for: option.id) != nil {
                current.insert(option.id)
            }
        }
        enabled = current
    }
}

private struct MoonX7V2GameModeButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .black, design: .rounded))
                .foregroundStyle(selected ? .white : .white.opacity(0.42))
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(
                    selected
                    ? LinearGradient(
                        colors: [MoonX7V2Palette.red.opacity(0.62), MoonX7V2Palette.purple.opacity(0.46)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    : LinearGradient(colors: [.white.opacity(0.035), .white.opacity(0.02)], startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(selected ? MoonX7V2Palette.red.opacity(0.55) : .white.opacity(0.07), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}

private struct MoonX7V2FilterButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 7.5, weight: .black, design: .rounded))
                .tracking(0.25)
                .foregroundStyle(selected ? .white : .white.opacity(0.35))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity)
                .frame(height: 35)
                .background(
                    selected ? MoonX7V2Palette.purple.opacity(0.22) : .white.opacity(0.025),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(selected ? MoonX7V2Palette.purpleBright.opacity(0.48) : .white.opacity(0.06), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}

private struct MoonX7V2PatchCard: View {
    let option: PatchOption
    @Binding var enabled: Set<String>
    @State private var expanded = false
    @State private var busy = false
    @State private var error: String?
    @State private var success: String?

    private var active: Bool { enabled.contains(option.id) }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill((option.isTexture ? MoonX7V2Palette.purple : MoonX7V2Palette.red).opacity(0.11))

                        Image(systemName: option.isTexture ? "sparkles" : "scope")
                            .font(.system(size: 17, weight: .black))
                            .foregroundStyle(option.isTexture ? MoonX7V2Palette.purpleBright : MoonX7V2Palette.redBright)
                    }
                    .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(option.title)
                            .font(.system(size: 13.5, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.leading)

                        Text(option.subtitle ?? "")
                            .font(.system(size: 8.5, weight: .black, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(.white.opacity(0.32))
                    }

                    Spacer()

                    if busy {
                        ProgressView().tint(.white)
                    } else {
                        Circle()
                            .fill(active ? MoonX7V2Palette.redBright : .clear)
                            .frame(width: 10, height: 10)
                            .overlay {
                                Circle()
                                    .stroke(active ? MoonX7V2Palette.redBright : .white.opacity(0.20), lineWidth: 1.3)
                                    .frame(width: 21, height: 21)
                            }
                    }

                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.white.opacity(0.30))
                }
                .padding(14)
            }
            .buttonStyle(.plain)

            if expanded {
                HStack(spacing: 9) {
                    MoonX7V2ActionButton(
                        title: option.isTexture ? "INJETAR" : "INJETAR 40%",
                        icon: "bolt.fill",
                        tint: MoonX7V2Palette.redBright,
                        disabled: busy
                    ) {
                        run(apply: true)
                    }

                    MoonX7V2ActionButton(
                        title: option.isTexture ? "QUITAR" : "QUITAR LOBBY",
                        icon: "arrow.uturn.backward",
                        tint: MoonX7V2Palette.purpleBright,
                        disabled: busy
                    ) {
                        run(apply: false)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .fill(Color.white.opacity(active ? 0.06 : 0.038))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .stroke(
                    active
                    ? MoonX7V2Palette.redBright.opacity(0.62)
                    : .white.opacity(0.075),
                    lineWidth: active ? 1.2 : 0.8
                )
        }
        .shadow(
            color: active ? MoonX7V2Palette.red.opacity(0.16) : .clear,
            radius: 20,
            y: 7
        )
        .alert("MOONX7", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .alert("MOONX7", isPresented: Binding(
            get: { success != nil },
            set: { if !$0 { success = nil } }
        )) {
            Button("OK") { success = nil }
        } message: {
            Text(success ?? "")
        }
    }

    private func run(apply: Bool) {
        guard !busy else { return }
        busy = true

        DispatchQueue.global(qos: .userInitiated).async {
            let result = PatchSlotRunner.setEnabled(
                apply,
                slotID: option.id,
                fileName: option.patchFile,
                configuredPassword: option.patchPassword
            )

            DispatchQueue.main.async {
                busy = false

                switch result {
                case .success:
                    if apply {
                        enabled.insert(option.id)
                    } else {
                        enabled.remove(option.id)
                    }
                    success = apply ? "Patch activado correctamente." : "Patch restaurado correctamente."
                case .failure(let err):
                    error = PatchSlotRunner.message(for: err)
                }
            }
        }
    }
}

private struct MoonX7V2ActionButton: View {
    let title: String
    let icon: String
    let tint: Color
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 9.5, weight: .black, design: .rounded))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 43)
        }
        .background(tint.opacity(disabled ? 0.18 : 0.28), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(disabled ? 0.16 : 0.48), lineWidth: 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

private struct MoonX7V2ConfigView: View {
    @ObservedObject var auth: MoonAuthManager

    private var maskedKey: String {
        guard let key = auth.licenseKey, key.count > 8 else { return auth.licenseKey ?? "—" }
        return String(key.prefix(4)) + "••••••••" + String(key.suffix(4))
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 15) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("CONFIG")
                        .font(.system(size: 30, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Text("ACCOUNT • APP • ABOUT")
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .tracking(1.8)
                        .foregroundStyle(MoonX7V2Palette.redBright)
                }
                .padding(.top, 26)

                MoonX7V2GlassCard(tint: MoonX7V2Palette.purple) {
                    VStack(alignment: .leading, spacing: 12) {
                        MoonX7V2SectionTitle("ACCOUNT", tint: MoonX7V2Palette.purpleBright)
                        MoonX7V2ConfigRow("USUARIO", "MOONX7")
                        MoonX7V2ConfigRow("KEY", maskedKey, mono: true)
                        MoonX7V2ConfigRow("PLAN", auth.plan?.uppercased() ?? "—")
                        MoonX7V2ConfigRow(
                            "EXPIRA",
                            auth.expiresAt?.formatted(date: .abbreviated, time: .shortened) ?? "—",
                            mono: true
                        )
                    }
                    .padding(17)
                }

                MoonX7V2GlassCard(tint: MoonX7V2Palette.red) {
                    VStack(alignment: .leading, spacing: 12) {
                        MoonX7V2SectionTitle("APP", tint: MoonX7V2Palette.redBright)
                        MoonX7V2ConfigRow("ESTADO", auth.isAuthenticated ? "ACTIVE" : "OFF")
                        MoonX7V2ConfigRow("DISPOSITIVO", DeviceInfo.machine)
                        MoonX7V2ConfigRow("IOS", UIDevice.current.systemVersion)
                        MoonX7V2ConfigRow("VERSION", "2.2.0")
                    }
                    .padding(17)
                }

                MoonX7V2GlassCard(tint: MoonX7V2Palette.silver) {
                    VStack(alignment: .leading, spacing: 12) {
                        MoonX7V2SectionTitle("ABOUT", tint: MoonX7V2Palette.silver)
                        MoonX7V2ConfigRow("APP", "MOONX7")
                        MoonX7V2ConfigRow("BUILD", "METALLIC EDITION")
                        MoonX7V2ConfigRow("SECURITY", "LICENSE • DEVICE")
                    }
                    .padding(17)
                }

                Button {
                    auth.signOut()
                } label: {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("CERRAR SESIÓN")
                    }
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                }
                .background(MoonX7V2Palette.red.opacity(0.22), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(MoonX7V2Palette.red.opacity(0.48), lineWidth: 1)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 95)
            }
            .padding(.horizontal, 15)
        }
    }
}

private struct MoonX7V2SectionTitle: View {
    let title: String
    let tint: Color

    init(_ title: String, tint: Color) {
        self.title = title
        self.tint = tint
    }

    var body: some View {
        Text(title)
            .font(.system(size: 9, weight: .black, design: .rounded))
            .tracking(1.8)
            .foregroundStyle(tint)
    }
}

private struct MoonX7V2ConfigRow: View {
    let title: String
    let value: String
    let mono: Bool

    init(_ title: String, _ value: String, mono: Bool = false) {
        self.title = title
        self.value = value
        self.mono = mono
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.system(size: 8.5, weight: .black, design: .rounded))
                .tracking(0.9)
                .foregroundStyle(.white.opacity(0.32))

            Spacer(minLength: 10)

            Text(value)
                .font(.system(size: 10.5, weight: .bold, design: mono ? .monospaced : .rounded))
                .foregroundStyle(.white.opacity(0.86))
                .multilineTextAlignment(.trailing)
        }
    }
}

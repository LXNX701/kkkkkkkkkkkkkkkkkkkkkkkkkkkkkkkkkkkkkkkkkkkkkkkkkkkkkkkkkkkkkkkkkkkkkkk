import Foundation
import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var auth: AuthProtection
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @AppStorage("external.darkMode") private var darkMode = true

    private var scheme: ColorScheme { darkMode ? .dark : .light }
    private var bg: Color { darkMode ? .black : Color(uiColor: .systemGroupedBackground) }

    var body: some View {
        ZStack(alignment: .bottom) {
            bg.ignoresSafeArea()

            Group {
                if tab == 0 {
                    ExternalFunctionsView(darkMode: darkMode)
                } else if tab == 1 {
                    TexturasView(darkMode: darkMode)
                } else {
                    ConfigDashboardView(darkMode: $darkMode)
                }
            }
            .padding(.bottom, 72)

            HStack(spacing: 8) {
                BottomItem(icon: "house.fill", title: "Function", selected: tab == 0, darkMode: darkMode) { requestTab(0) }
                BottomItem(icon: "figure.stand", title: "Texturas", selected: tab == 1, darkMode: darkMode) { requestTab(1) }
                BottomItem(icon: "cube.fill", title: "Config", selected: tab == 2, darkMode: darkMode) { requestTab(2) }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 8)

            if !auth.isAuthorized {
                MoonX7LoginScreen()
                    .zIndex(100)
            }
        }
        .environment(\.colorScheme, scheme)
        .preferredColorScheme(scheme)
        .task {
            await auth.bootstrap()
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task { @MainActor in
                await auth.appBecameActive()
            }
        }
    }

    private func requestTab(_ newTab: Int) {
        Task { @MainActor in
            guard let permit = await auth.permit(for: .tabNavigation),
                  AuthProtection.validatePermit(permit, for: .tabNavigation) else { return }
            tab = newTab
        }
    }
}

private struct MoonX7LoginScreen: View {
    @EnvironmentObject private var auth: AuthProtection
    @State private var licenseKey = ""
    @State private var busy = false
    @State private var animate = false

    private let purple = Color(red: 0.55, green: 0.16, blue: 0.95)
    private let pink = Color(red: 1.0, green: 0.20, blue: 0.60)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            RadialGradient(
                colors: [
                    purple.opacity(0.40),
                    pink.opacity(0.14),
                    .clear
                ],
                center: animate ? .topLeading : .bottomTrailing,
                startRadius: 10,
                endRadius: 520
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 4).repeatForever(autoreverses: true), value: animate)

            Circle()
                .stroke(
                    AngularGradient(
                        colors: [purple.opacity(0.85), pink.opacity(0.9), purple.opacity(0.85)],
                        center: .center
                    ),
                    lineWidth: 1
                )
                .frame(width: 420, height: 420)
                .blur(radius: 0.3)
                .opacity(0.20)
                .rotationEffect(.degrees(animate ? 360 : 0))
                .animation(.linear(duration: 14).repeatForever(autoreverses: false), value: animate)

            VStack(spacing: 0) {
                Spacer(minLength: 28)

                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [purple, pink],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 84, height: 84)
                            .shadow(color: purple.opacity(0.55), radius: 22)

                        Image(systemName: "moon.stars.fill")
                            .font(.system(size: 35, weight: .bold))
                            .foregroundStyle(.white)
                    }

                    Text("MOONX7")
                        .font(.system(size: 34, weight: .black, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white, pink.opacity(0.95), purple.opacity(0.98)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )

                    HStack(spacing: 7) {
                        Circle()
                            .fill(pink)
                            .frame(width: 5, height: 5)
                        Text("EXTERNAL · iOS")
                    }
                    .font(.system(size: 10, weight: .bold))
                    .tracking(3)
                    .foregroundStyle(.white.opacity(0.48))
                }

                Spacer(minLength: 30)

                VStack(alignment: .leading, spacing: 16) {
                    Text("Accede a MOONX7")
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Ingresa tu key para desbloquear el panel MoonX7 en este dispositivo.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.50))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Image(systemName: "key.fill")
                            .foregroundStyle(purple.opacity(0.95))

                        TextField("MOONX7-XXXX-XXXX", text: $licenseKey)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .foregroundStyle(.white)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .submitLabel(.go)
                            .onSubmit { login() }

                        Button {
                            licenseKey = UIPasteboard.general.string ?? ""
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                                .foregroundStyle(.white.opacity(0.58))
                        }
                    }
                    .padding(.horizontal, 15)
                    .frame(height: 54)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    )

                    Button(action: login) {
                        HStack(spacing: 9) {
                            if busy {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "lock.open.fill")
                            }
                            Text(busy ? "VERIFICANDO..." : "ENTRAR A MOONX7")
                        }
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                    }
                    .foregroundStyle(.white)
                    .background(
                        LinearGradient(
                            colors: [purple, pink],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: 16)
                    )
                    .shadow(color: purple.opacity(0.32), radius: 18, y: 8)
                    .disabled(busy || licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if !auth.lockMessage.isEmpty {
                        Text(auth.lockMessage)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.red.opacity(0.86))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "shield.lefthalf.filled")
                        Text("MOONX7 · CONTROL DE ACCESO")
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.32))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
                .overlay(
                    RoundedRectangle(cornerRadius: 28)
                        .stroke(
                            LinearGradient(
                                colors: [purple.opacity(0.42), pink.opacity(0.20)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: .black.opacity(0.50), radius: 34, y: 18)

                Spacer(minLength: 28)
            }
            .padding(.horizontal, 22)
            .frame(maxWidth: 520)
        }
        .onAppear { animate = true }
        .preferredColorScheme(.dark)
    }

    private func login() {
        guard !busy else { return }
        let value = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }

        busy = true

        Task { @MainActor in
            _ = await auth.loginWithKey(value)
            licenseKey = value
            busy = false
        }
    }
}

private struct PatchOption: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let patchFile: String
    let patchPassword: String
}

private enum PatchSlots {
    // EDITE SOMENTE os nomes e senhas abaixo.
    // password = "0" significa SEM SENHA.
    static let aimAssist = "aim-assist.3105"
    static let aimAssistPassword = "0"

    static let aimBotEsp = "aim-bot-esp.3105"
    static let aimBotEspPassword = "OG"

    // HS ALTO + PESCOÇO: dois patches separados.
    static let hsAltoNeckSemAntena = "hs-alto-neck-sem-antena.3105"
    static let hsAltoNeckSemAntenaPassword = "0"
    static let hsAltoNeckComAntena = "hs-alto-neck-com-antena.3105"
    static let hsAltoNeckComAntenaPassword = "0"

    // HS ALTO: usa popup de antena; apenas a opção COM fica habilitada.
    static let hsAlto = "hs-alto.3105"
    static let hsAltoPassword = "0"

    // HS PESCOÇO: dois patches separados.
    static let hsNeckSemAntena = "hs-neck-sem-antena.3105"
    static let hsNeckSemAntenaPassword = "0"
    static let hsNeckComAntena = "hs-neck-com-antena.3105"
    static let hsNeckComAntenaPassword = "0"

    static let hsPeito = "hs-peito.3105"
    static let hsPeitoPassword = "0"

    static let magicBullet = "magic-bullet.3105"
    static let magicBulletPassword = "0"

    static let fps120144 = "120-144-fps.3105"
    static let fps120144Password = "OG"

    static let hologramaPreto = "holograma-preto.3105"
    static let hologramaPretoPassword = "0"
}

private enum AntennaChoice {
    case withAntenna
    case withoutAntenna
}

private struct RuntimePatchConfig {
    let fileName: String
    let password: String
}

private enum PatchSelectionRules {
    static let headshotIDs: Set<String> = [
        "alto-pescoco",
        "alto",
        "pescoco",
        "peito"
    ]

    static let aimBotID = "aimbot-esp"
    static let hologramID = "holograma-preto"

    static func isHeadshot(_ id: String) -> Bool {
        headshotIDs.contains(id)
    }

    // Combinações permitidas:
    // - apenas uma opção sozinha;
    // - AIM BOT + ESP 4 DEDOS + um único HS;
    // - HOLOGRAMA GUNS + um único HS.
    // Dois HS nunca permanecem ligados ao mesmo tempo.
    static func canEnable(_ id: String, current: Set<String>) -> Bool {
        let others = current.subtracting(Set([id]))
        guard !others.isEmpty else { return true }

        if isHeadshot(id) {
            let nonHeadshots = others.subtracting(headshotIDs)
            return nonHeadshots.isEmpty ||
                nonHeadshots == Set([aimBotID]) ||
                nonHeadshots == Set([hologramID])
        }

        if id == aimBotID {
            return others.count == 1 && others.isSubset(of: headshotIDs)
        }

        if id == hologramID {
            return others.count == 1 && others.isSubset(of: headshotIDs)
        }

        return false
    }
}

private struct ExternalFunctionsView: View {
    @EnvironmentObject private var auth: AuthProtection
    let darkMode: Bool
    @State private var game = 0
    @State private var enabled: Set<String> = []

    private let aimEsp = [
        PatchOption(id: "aimbot-esp", title: "AIM BOT + ESP 4 DEDOS", subtitle: nil, patchFile: PatchSlots.aimBotEsp, patchPassword: PatchSlots.aimBotEspPassword)
    ]
    private let headshots = [
        PatchOption(id: "alto-pescoco", title: "HS ALTO + PESCOÇO", subtitle: "Hs Acima da Cabeça e no Pescoço.", patchFile: PatchSlots.hsAltoNeckSemAntena, patchPassword: PatchSlots.hsAltoNeckSemAntenaPassword),
        PatchOption(id: "alto", title: "HS ALTO", subtitle: "Hs Acima da Cabeça.", patchFile: PatchSlots.hsAlto, patchPassword: PatchSlots.hsAltoPassword),
        PatchOption(id: "pescoco", title: "HS PESCOÇO", subtitle: "Hs Apenas no Pescoço do inimigo.", patchFile: PatchSlots.hsNeckSemAntena, patchPassword: PatchSlots.hsNeckSemAntenaPassword),
        PatchOption(id: "peito", title: "HS PEITO", subtitle: "Hs No Peito do inimigo.", patchFile: PatchSlots.hsPeito, patchPassword: PatchSlots.hsPeitoPassword),
        PatchOption(id: "magic-bullet", title: "MAGIC BULLET", subtitle: "Bala magica", patchFile: PatchSlots.magicBullet, patchPassword: PatchSlots.magicBulletPassword),
        PatchOption(id: "120-144-fps", title: "120/144 FPS", subtitle: nil, patchFile: PatchSlots.fps120144, patchPassword: PatchSlots.fps120144Password)
    ]
    private let holograms = [
        PatchOption(id: "holograma-preto", title: "HOLOGRAMA GUNS", subtitle: "holograma nas armas", patchFile: PatchSlots.hologramaPreto, patchPassword: PatchSlots.hologramaPretoPassword)
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                MoonX7FunctionsHeader(darkMode: darkMode)
                    .padding(.top, 18)
                    .padding(.bottom, 14)

                HStack(spacing: 12) {
                    GameButton("Free Fire Normal", selected: game == 0, darkMode: darkMode) { requestGame(0) }
                    GameButton("Free Fire Max", selected: game == 1, darkMode: darkMode) { requestGame(1) }
                }

                if game == 0 {
                    SectionBlock(title: "AIM / ESP", rows: aimEsp, enabled: $enabled, darkMode: darkMode, manualControls: false).padding(.top, 24)
                    SectionBlock(title: "HEADSHOTS", rows: headshots, enabled: $enabled, darkMode: darkMode, manualControls: true).padding(.top, 24)
                    SectionBlock(title: "HOLOGRAMAS", rows: holograms, enabled: $enabled, darkMode: darkMode, manualControls: false).padding(.top, 24)
                    Spacer().frame(height: 75)
                } else {
                    VStack {
                        Spacer().frame(height: 125)
                        Text("Na próxima atualização da external :)")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(darkMode ? Color.white.opacity(0.62) : Color.black.opacity(0.55))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                        Spacer().frame(height: 160)
                    }
                }
            }
            .padding(.horizontal, 22)
        }
        .background(
            ZStack {
                (darkMode ? Color.black : Color(uiColor: .systemGroupedBackground))
                    .ignoresSafeArea()
                RadialGradient(
                    colors: [
                        Color(red: 0.50, green: 0.08, blue: 0.84).opacity(0.20),
                        Color(red: 0.86, green: 0.08, blue: 0.42).opacity(0.08),
                        .clear
                    ],
                    center: .topTrailing,
                    startRadius: 20,
                    endRadius: 520
                )
                .ignoresSafeArea()
            }
        )
    }

    private func requestGame(_ newGame: Int) {
        Task { @MainActor in
            guard let permit = await auth.permit(for: .gameSelection),
                  AuthProtection.validatePermit(permit, for: .gameSelection) else { return }
            game = newGame
        }
    }
}

private struct MoonX7FunctionsHeader: View {
    @EnvironmentObject private var auth: AuthProtection
    let darkMode: Bool

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.52, green: 0.15, blue: 0.95),
                                Color(red: 0.90, green: 0.16, blue: 0.60)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 50, height: 50)
                    .shadow(color: Color(red: 0.72, green: 0.20, blue: 0.90).opacity(0.35), radius: 15)

                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("MOONX7")
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(red: 0.84, green: 0.54, blue: 1.0),
                                Color(red: 1.0, green: 0.34, blue: 0.70)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                Text("LICENSED ACCESS")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(darkMode ? .white.opacity(0.38) : .black.opacity(0.38))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("ACTIVE")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(Color.green)

                Text(auth.expirationDisplay)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(darkMode ? .white.opacity(0.42) : .black.opacity(0.42))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color(red: 0.72, green: 0.32, blue: 0.98).opacity(0.22), lineWidth: 1)
        )
    }
}

private struct GameButton: View {
    let title: String; let selected: Bool; let darkMode: Bool; let action: () -> Void
    init(_ title: String, selected: Bool, darkMode: Bool, action: @escaping () -> Void) {
        self.title=title; self.selected=selected; self.darkMode=darkMode; self.action=action
    }
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(darkMode ? .white : .black)
                .frame(maxWidth: .infinity).frame(height: 54)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(
                    selected ? Color(red: 0.72, green: 0.32, blue: 0.98) :
                        (darkMode ? Color.white.opacity(0.25) : Color.black.opacity(0.20)), lineWidth: 1.5))
        }.buttonStyle(.plain)
    }
}

private struct SectionBlock: View {
    @EnvironmentObject private var auth: AuthProtection
    let title: String
    let rows: [PatchOption]
    @Binding var enabled: Set<String>
    let darkMode: Bool
    let manualControls: Bool

    @State private var busy: Set<String> = []
    @State private var successPresented = false
    @State private var successMessage = "Ativado com sucesso!"
    @State private var errorMessage: String?
    @State private var antennaPromptRow: PatchOption?
    @State private var antennaChoices: [String: AntennaChoice] = [:]
    @State private var crouchInstructionPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color(red: 0.96, green: 0.30, blue: 0.70))

            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.title)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(darkMode ? .white : .black)

                            if let subtitle = displaySubtitle(for: row), !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.system(size: 12.5, weight: .regular))
                                    .foregroundStyle(
                                        darkMode ? Color.white.opacity(0.46) : Color.black.opacity(0.46)
                                    )
                            }
                        }

                        Spacer(minLength: 8)

                        if busy.contains(row.id) {
                            ProgressView().scaleEffect(0.85)
                        }

                        Toggle("", isOn: Binding(
                            get: { enabled.contains(row.id) },
                            set: { on in
                                handleToggle(row: row, enabledState: on)
                            }
                        ))
                        .labelsHidden()
                        .scaleEffect(0.88)
                        .disabled(busy.contains(row.id))
                    }
                    .frame(minHeight: 36)

                    if manualControls && row.id != "120-144-fps" && enabled.contains(row.id) && !isOptionDisabled(row) {
                        HStack(spacing: 12) {
                            actionCard("INJETAR (40%)") {
                                runManual(row: row, apply: true)
                            }
                            actionCard("LOBBY") {
                                runManual(row: row, apply: false)
                            }
                        }
                        .padding(.bottom, 4)
                    }
                }
                .disabled(isOptionDisabled(row))
                .opacity(isOptionDisabled(row) ? 0.32 : 1.0)
                .allowsHitTesting(!isOptionDisabled(row))
            }
        }
        .alert(
            "Ativar antena?",
            isPresented: Binding(
                get: { antennaPromptRow != nil },
                set: { if !$0 { antennaPromptRow = nil } }
            ),
            presenting: antennaPromptRow
        ) { row in
            Button("sem") {
                confirmAntennaChoice(.withoutAntenna, for: row)
            }
            .disabled(isWithoutAntennaDisabled(row))

            Button("com") {
                confirmAntennaChoice(.withAntenna, for: row)
            }
        } message: { _ in
            Text("Escolha qual versão deseja usar.")
        }
        .alert("Aviso", isPresented: $crouchInstructionPresented) {
            Button("OK") { }
        } message: {
            Text("Agache 2 vezes para alterar o aimbot")
        }
        .alert("Sucesso", isPresented: $successPresented) {
            Button("OK") { }
        } message: {
            Text(successMessage)
        }
        .alert("MOONX7", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func actionCard(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
    }

    private func handleToggle(row: PatchOption, enabledState: Bool) {
        guard !busy.contains(row.id), !isOptionDisabled(row) else { return }

        if enabledState && PatchSelectionRules.isHeadshot(row.id) {
            prepareHeadshotSelection(row)
            return
        }

        if enabledState && !PatchSelectionRules.canEnable(row.id, current: enabled) {
            errorMessage = combinationErrorMessage
            return
        }

        // AIM BOT + ESP 4 DEDOS: show the crouch instruction immediately
        // when the user turns the switch on. Presenting it here avoids losing
        // the alert during the asynchronous authorization/state update.
        if enabledState && row.id == "aimbot-esp" {
            crouchInstructionPresented = true
        }

        if manualControls && row.id != "120-144-fps" {
            if !enabledState, appliedConfig(for: row) != nil {
                // Turning a manually injected option off must not strand its backup.
                // Use the same restore path as LOBBY.
                runManual(row: row, apply: false)
                return
            }

            Task { @MainActor in
                busy.insert(row.id)
                defer { busy.remove(row.id) }

                guard let permit = await auth.permit(for: .patchToggle),
                      AuthProtection.validatePermit(permit, for: .patchToggle) else {
                    errorMessage = "Autenticação obrigatória. Valide sua key novamente."
                    return
                }

                if enabledState {
                    enabled.insert(row.id)
                } else {
                    enabled.remove(row.id)
                    if requiresAntennaChoice(row) {
                        antennaChoices.removeValue(forKey: row.id)
                    }
                }
            }
        } else {
            run(row: row, enabledState: enabledState)
        }
    }

    private func prepareHeadshotSelection(_ row: PatchOption) {
        guard PatchSelectionRules.isHeadshot(row.id), !busy.contains(row.id) else { return }

        guard PatchSelectionRules.canEnable(row.id, current: enabled) else {
            errorMessage = combinationErrorMessage
            return
        }

        Task { @MainActor in
            let previousRows = rows.filter { candidate in
                candidate.id != row.id &&
                PatchSelectionRules.isHeadshot(candidate.id) &&
                (enabled.contains(candidate.id) || appliedConfig(for: candidate) != nil)
            }

            busy.insert(row.id)
            previousRows.forEach { busy.insert($0.id) }
            defer {
                busy.remove(row.id)
                previousRows.forEach { busy.remove($0.id) }
            }

            guard let togglePermit = await auth.permit(for: .patchToggle),
                  AuthProtection.validatePermit(togglePermit, for: .patchToggle) else {
                errorMessage = "Autenticação obrigatória. Valide sua key novamente."
                return
            }

            // One HS at a time. If the previous HS was already injected, restore
            // its exact receipt first so the UI and the real files never diverge.
            for previous in previousRows {
                if let config = appliedConfig(for: previous) {
                    guard let restorePermit = await auth.permit(for: .patchRestore),
                          AuthProtection.validatePermit(restorePermit, for: .patchRestore) else {
                        errorMessage = "Autenticação obrigatória. Valide sua key novamente."
                        return
                    }

                    let result = await performPatchOperation(
                        false,
                        config: config,
                        permit: restorePermit,
                        action: .patchRestore
                    )

                    if case .failure(let error) = result {
                        errorMessage = PatchSlotRunner.message(for: error)
                        return
                    }
                }

                enabled.remove(previous.id)
                antennaChoices.removeValue(forKey: previous.id)
            }

            if requiresAntennaChoice(row) {
                // Keep the new switch OFF until sem/com is chosen.
                antennaPromptRow = row
            } else {
                enabled.insert(row.id)
            }
        }
    }

    private func confirmAntennaChoice(_ choice: AntennaChoice, for row: PatchOption) {
        guard requiresAntennaChoice(row), !busy.contains(row.id) else { return }

        if choice == .withoutAntenna && isWithoutAntennaDisabled(row) {
            return
        }

        guard PatchSelectionRules.canEnable(row.id, current: enabled) else {
            errorMessage = combinationErrorMessage
            return
        }

        Task { @MainActor in
            busy.insert(row.id)
            defer { busy.remove(row.id) }

            guard let permit = await auth.permit(for: .patchToggle),
                  AuthProtection.validatePermit(permit, for: .patchToggle) else {
                errorMessage = "Autenticação obrigatória. Valide sua key novamente."
                return
            }

            // If a variant is currently applied, do not let the UI silently switch
            // to the other file before the original backup has been restored.
            if let applied = appliedVariant(for: row), applied != choice {
                errorMessage = "Use LOBBY para restaurar a opção anterior antes de trocar sem/com."
                return
            }

            antennaChoices[row.id] = choice
            enabled.insert(row.id)

            if row.id == "alto-pescoco" && choice == .withAntenna {
                antennaPromptRow = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    crouchInstructionPresented = true
                }
            }
        }
    }

    private func run(row: PatchOption, enabledState: Bool) {
        guard !busy.contains(row.id) else { return }
        busy.insert(row.id)

        Task { @MainActor in
            guard let permit = await auth.permit(for: .patchToggle),
                  AuthProtection.validatePermit(permit, for: .patchToggle) else {
                busy.remove(row.id)
                errorMessage = "Autenticação obrigatória. Valide sua key novamente."
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                let result = PatchSlotRunner.setEnabled(
                    enabledState,
                    fileName: row.patchFile,
                    configuredPassword: row.patchPassword,
                    permit: permit,
                    action: .patchToggle
                )
                DispatchQueue.main.async {
                    busy.remove(row.id)
                    switch result {
                    case .success:
                        if enabledState {
                            enabled.insert(row.id)
                            successMessage = row.id == "120-144-fps" ? "Ativado. Feche seu jogo e abra de novo." : "Ativado com sucesso!"
                            successPresented = true
                        }
                        else {
                            enabled.remove(row.id)
                            if requiresAntennaChoice(row) {
                                antennaChoices.removeValue(forKey: row.id)
                            }
                            successMessage = "Desinjetado com sucesso!"
                            successPresented = true
                        }
                    case .failure(let error):
                        errorMessage = PatchSlotRunner.message(for: error)
                    }
                }
            }
        }
    }

    private func runManual(row: PatchOption, apply: Bool) {
        guard !busy.contains(row.id) else { return }

        guard let config = runtimeConfig(for: row, restoring: !apply) else {
            errorMessage = requiresAntennaChoice(row)
                ? "Selecione sem ou com antena primeiro."
                : "Patch não encontrado."
            return
        }

        if apply, requiresAntennaChoice(row), let applied = appliedVariant(for: row) {
            let selected = antennaChoices[row.id]
            if selected != applied {
                errorMessage = "Use LOBBY para restaurar a opção anterior antes de trocar sem/com."
                return
            }
        }

        busy.insert(row.id)

        Task { @MainActor in
            let action: ProtectedAction = apply ? .patchApply : .patchRestore
            guard let permit = await auth.permit(for: action),
                  AuthProtection.validatePermit(permit, for: action) else {
                busy.remove(row.id)
                errorMessage = "Autenticação obrigatória. Valide sua key novamente."
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                let result = PatchSlotRunner.setEnabled(
                    apply,
                    fileName: config.fileName,
                    configuredPassword: config.password,
                    permit: permit,
                    action: action
                )
                DispatchQueue.main.async {
                    busy.remove(row.id)
                    switch result {
                    case .success:
                        if apply {
                            successMessage = "Ativado com sucesso!"
                            successPresented = true
                        } else {
                            enabled.remove(row.id)
                            if requiresAntennaChoice(row) {
                                antennaChoices.removeValue(forKey: row.id)
                            }
                            successMessage = "Desinjetado com sucesso!"
                            successPresented = true
                        }
                    case .failure(let error):
                        errorMessage = PatchSlotRunner.message(for: error)
                    }
                }
            }
        }
    }

    private var combinationErrorMessage: String {
        "Combinação não permitida. Use apenas um HS por vez; AIM BOT + ESP 4 DEDOS ou HOLOGRAMA GUNS podem ser usados junto de um HS."
    }

    private func appliedConfig(for row: PatchOption) -> RuntimePatchConfig? {
        if requiresAntennaChoice(row) {
            guard let applied = appliedVariant(for: row) else { return nil }
            return antennaConfig(for: row, choice: applied)
        }

        let config = RuntimePatchConfig(fileName: row.patchFile, password: row.patchPassword)
        return PatchSlotBackupRegistry.receipt(for: config.fileName) == nil ? nil : config
    }

    private func performPatchOperation(
        _ enabledState: Bool,
        config: RuntimePatchConfig,
        permit: ActionPermit,
        action: ProtectedAction
    ) async -> Result<String, Error> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = PatchSlotRunner.setEnabled(
                    enabledState,
                    fileName: config.fileName,
                    configuredPassword: config.password,
                    permit: permit,
                    action: action
                )
                continuation.resume(returning: result)
            }
        }
    }

    private func requiresAntennaChoice(_ row: PatchOption) -> Bool {
        row.id == "alto-pescoco" || row.id == "alto" || row.id == "pescoco" || row.id == "peito"
    }

    private func isWithoutAntennaDisabled(_ row: PatchOption) -> Bool {
        row.id == "alto" || row.id == "pescoco" || row.id == "peito"
    }

    private func isOptionDisabled(_ row: PatchOption) -> Bool {
        row.id == "magic-bullet" || row.id == "120-144-fps"
    }

    private func displaySubtitle(for row: PatchOption) -> String? {
        row.subtitle
    }

    private func runtimeConfig(for row: PatchOption, restoring: Bool) -> RuntimePatchConfig? {
        guard requiresAntennaChoice(row) else {
            return RuntimePatchConfig(fileName: row.patchFile, password: row.patchPassword)
        }

        if restoring, let applied = appliedVariant(for: row) {
            return antennaConfig(for: row, choice: applied)
        }

        guard let choice = antennaChoices[row.id] else { return nil }
        return antennaConfig(for: row, choice: choice)
    }

    private func antennaConfig(for row: PatchOption, choice: AntennaChoice) -> RuntimePatchConfig? {
        switch (row.id, choice) {
        case ("alto-pescoco", .withAntenna):
            return RuntimePatchConfig(
                fileName: PatchSlots.hsAltoNeckComAntena,
                password: PatchSlots.hsAltoNeckComAntenaPassword
            )
        case ("alto-pescoco", .withoutAntenna):
            return RuntimePatchConfig(
                fileName: PatchSlots.hsAltoNeckSemAntena,
                password: PatchSlots.hsAltoNeckSemAntenaPassword
            )
        case ("alto", .withAntenna):
            return RuntimePatchConfig(
                fileName: PatchSlots.hsAlto,
                password: PatchSlots.hsAltoPassword
            )
        case ("pescoco", .withAntenna):
            return RuntimePatchConfig(
                fileName: PatchSlots.hsNeckComAntena,
                password: PatchSlots.hsNeckComAntenaPassword
            )
        case ("pescoco", .withoutAntenna):
            return RuntimePatchConfig(
                fileName: PatchSlots.hsNeckSemAntena,
                password: PatchSlots.hsNeckSemAntenaPassword
            )
        case ("peito", .withAntenna):
            return RuntimePatchConfig(
                fileName: PatchSlots.hsPeito,
                password: PatchSlots.hsPeitoPassword
            )
        default:
            return nil
        }
    }

    private func appliedVariant(for row: PatchOption) -> AntennaChoice? {
        guard requiresAntennaChoice(row) else { return nil }

        if let withConfig = antennaConfig(for: row, choice: .withAntenna),
           PatchSlotBackupRegistry.receipt(for: withConfig.fileName) != nil {
            return .withAntenna
        }

        if let withoutConfig = antennaConfig(for: row, choice: .withoutAntenna),
           PatchSlotBackupRegistry.receipt(for: withoutConfig.fileName) != nil {
            return .withoutAntenna
        }

        return nil
    }

}

private enum PatchSlotRunner {
    // Uses the SAME package decoder + DevicePatchService used by the original
    // project's Apply/Restore buttons. PatchTransaction therefore creates and
    // validates the original backup/journal before replacing files.
    static func setEnabled(
        _ enabled: Bool,
        fileName: String,
        configuredPassword: String,
        permit: ActionPermit,
        action: ProtectedAction
    ) -> Result<String, Error> {
        do {
            guard AuthProtection.validatePermit(permit, for: action) else {
                throw PatchSlotError.authorizationRequired
            }

            if enabled {
                let data: Data
                do {
                    data = try EmbeddedPatchVault.data(named: fileName)
                } catch EmbeddedPatchVaultError.missingPatch {
                    throw PatchSlotError.missingPatch
                }

                // "0" = package without password. Any other value is passed to the
                // same decoder used by the original 3105 password flow.
                let password: String? = configuredPassword == "0" ? nil : configuredPassword
                let decoded = try PatchPackageCodec.decode(data, password: password)

                // PatchTransaction creates + verifies every original backup before
                // it writes the first replacement byte. Persist the exact receipt
                // by UI slot so Restore never needs the patch package again.
                let receipt = try DevicePatchService.apply(project: decoded.project)
                PatchSlotBackupRegistry.save(receipt, for: fileName)
                return .success("Patch aplicado. Backup original criado.")
            } else {
                guard let receipt = PatchSlotBackupRegistry.receipt(for: fileName) else {
                    throw PatchSlotError.noBackup
                }
                try DevicePatchService.restore(receipt: receipt)
                PatchSlotBackupRegistry.remove(for: fileName)
                return .success("Backup restaurado. Arquivos originais recuperados.")
            }
        } catch {
            return .failure(error)
        }
    }

    static func message(for error: Error) -> String {
        if let slotError = error as? PatchSlotError {
            switch slotError {
            case .missingPatch:
                return "Patch não encontrado."
            case .noBackup:
                return "Backup não encontrado."
            case .authorizationRequired:
                return "Autenticação obrigatória."
            }
        }
        if let patchError = error as? PatchPackageError {
            switch patchError {
            case .restoreFailed:
                return "Falha ao restaurar backup."
            default:
                return "Falha ao aplicar patch."
            }
        }
        return "Operação não concluída."
    }


    private enum PatchSlotError: Error {
        case missingPatch
        case noBackup
        case authorizationRequired
    }
}

private enum PatchSlotBackupRegistry {
    private struct Entry: Codable {
        let transactionID: UUID
        let projectID: UUID
    }

    private static let defaultsKey = "external.patch.slot.backups.v1"

    static func save(_ receipt: PatchTransactionReceipt, for slot: String) {
        var entries = load()
        entries[slot] = Entry(
            transactionID: receipt.id,
            projectID: receipt.projectID
        )
        persist(entries)
    }

    static func receipt(for slot: String) -> PatchTransactionReceipt? {
        var entries = load()
        guard let entry = entries[slot],
              let backupRoot = try? PatchProjectLibrary.backupRootURL() else {
            return nil
        }

        let journalURL = backupRoot
            .appendingPathComponent(entry.projectID.uuidString, isDirectory: true)
            .appendingPathComponent(entry.transactionID.uuidString, isDirectory: true)
            .appendingPathComponent("journal.plist")

        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            entries.removeValue(forKey: slot)
            persist(entries)
            return nil
        }

        return PatchTransactionReceipt(
            id: entry.transactionID,
            projectID: entry.projectID,
            journalURL: journalURL
        )
    }

    static func remove(for slot: String) {
        var entries = load()
        entries.removeValue(forKey: slot)
        persist(entries)
    }

    private static func load() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let entries = try? PropertyListDecoder().decode([String: Entry].self, from: data) else {
            return [:]
        }
        return entries
    }

    private static func persist(_ entries: [String: Entry]) {
        if entries.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return
        }
        guard let data = try? PropertyListEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

private struct TexturasView: View {
    let darkMode: Bool
    var body: some View {
        ZStack {
            (darkMode ? Color.black : Color(uiColor:.systemGroupedBackground)).ignoresSafeArea()
            Text("Em desenvolvimento pra nova atualização")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(darkMode ? Color.white.opacity(0.62) : Color.black.opacity(0.55))
                .multilineTextAlignment(.center).padding(.horizontal, 34)
        }
    }
}

private struct ConfigDashboardView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var auth: AuthProtection
    @Binding var darkMode: Bool
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section("CONTA") {
                    LabeledContent("Key", value: auth.displayedKey)
                    LabeledContent("Expira em", value: auth.expirationDisplay)
                    LabeledContent("Build", value: "10")
                    LabeledContent("Versão", value: "1.10")
                }
                Section {
                    LabeledContent("Phone", value: DeviceInfo.machine)
                    LabeledContent("Modelo de hardware", value: DeviceInfo.machine)
                    LabeledContent("Versão do iOS", value: UIDevice.current.systemVersion)
                    HStack {
                        Text("Compatibilidade"); Spacer()
                        Label(appState.isSupported ? "Suportado" : "Não suportado",
                              systemImage: appState.isSupported ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(appState.isSupported ? Color.green : Color.red)
                    }
                } header: { Text("DISPOSITIVO") }
                footer: { Text("Verificado: iOS 26.0–26.6.1 e builds listados do iOS 27.") }

                Section("APARÊNCIA") {
                    Toggle(isOn: Binding(get: { darkMode }, set: { darkMode = $0 })) {
                        Label(darkMode ? "Modo escuro" : "Modo claro",
                              systemImage: darkMode ? "moon.fill" : "sun.max.fill")
                    }
                }
                Section("CONTA") {
                    Button(role: .destructive) {
                        auth.logout()
                    } label: {
                        Label("Cerrar sesión MOONX7", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
                Section("INSTALAÇÃO") {
                    Label("Certificado enterprise", systemImage: "checkmark.seal")
                }
            }
            .font(.system(size: 15))
            .navigationTitle("Config")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName:"gearshape") }
                }
            }
            .tint(Color(red: 0.72, green: 0.32, blue: 0.98))
            .sheet(isPresented: $showSettings) {
                SettingsView().preferredColorScheme(darkMode ? .dark : .light)
            }
        }
    }
}

private enum DeviceInfo {
    static var machine: String {
        var systemInfo = utsname(); uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
    }
}

private struct BottomItem: View {
    let icon:String; let title:String; let selected:Bool; let darkMode:Bool; let action:()->Void
    var body: some View {
        Button(action:action) {
            VStack(spacing:3) {
                Image(systemName:icon).font(.system(size:19))
                Text(title).font(.system(size:11.5))
            }
            .foregroundStyle(selected ? Color(red:0.58,green:0.77,blue:0.94) :
                                (darkMode ? Color.white.opacity(0.50) : Color.black.opacity(0.48)))
            .frame(maxWidth:.infinity).frame(height:56)
            .background(selected ? (darkMode ? Color.white.opacity(0.09) : Color.black.opacity(0.07)) : .clear,
                        in: RoundedRectangle(cornerRadius:24))
        }.buttonStyle(.plain)
    }
}

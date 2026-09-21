import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var appState: AppState
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue
    @AppStorage("external.darkMode") private var darkMode = true

    private var isPT: Bool { languageCode == AppLanguage.portugueseBrazil.rawValue }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 27) {
                    MoonCommunityBanner()
                        .frame(maxWidth: .infinity)
                        .frame(height: 118)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(Color(red: 0.18, green: 0.84, blue: 1.00).opacity(0.62), lineWidth: 1.2)
                        )

                    settingHeader(isPT ? "Idioma" : "Language")
                    Picker(isPT ? "Idioma" : "Language", selection: $languageCode) {
                        ForEach(AppLanguage.allCases) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    settingHeader(isPT ? "Dispositivo" : "Device")
                    compactRow(isPT ? "Modelo de hardware" : "Hardware model", AppInfo.displayMachineName)
                    compactRow(isPT ? "Versão do iOS" : "iOS Version", AppInfo.osVersion)

                    settingHeader(isPT ? "Versões verificadas" : "Verified versions")
                    HStack {
                        Text(isPT ? "Versão atual" : "Current version")
                        Spacer()
                        Image(systemName: appState.isSupported ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(appState.isSupported ? .green : .red)
                        Text(appState.isSupported
                             ? (isPT ? "Suportado" : "Supported")
                             : (isPT ? "Não suportado" : "Unsupported"))
                            .foregroundStyle(appState.isSupported ? .green : .red)
                    }

                    compactRow("iOS 26", ExploitSupportPolicy.verifiedIOS26Range)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("iOS 27.0")
                        ForEach(ExploitSupportPolicy.verifiedIOS27Builds, id: \.build) { v in
                            Text("\(isPT ? "Beta" : "Beta") \(v.beta)  ·  \(v.build)")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(isPT
                         ? "Somente as builds listadas acima estão habilitadas. Builds mais novas podem aparecer como não suportadas."
                         : "Only the builds listed above are enabled. Newer builds may be marked unsupported.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)

                    settingHeader(isPT ? "Comunidade" : "Community")
                    Link(destination: URL(string: "https://discord.gg/hD6qXCtXm")!) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("MOON Community").font(.headline)
                                Text(isPT ? "Entrar no Discord" : "Join Discord")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }
                        .foregroundStyle(Color(red: 0.18, green: 0.84, blue: 1.00))
                        .frame(minHeight: 44)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 34)
                .padding(.top, 36)
                .padding(.bottom, 44)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(isPT ? "Ajustes" : "Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isPT ? "Concluído" : "Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(Color(red: 0.58, green: 0.78, blue: 0.98))
                }
            }
            .tint(Color(red: 0.58, green: 0.78, blue: 0.98))
        }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
    }

    private func settingHeader(_ s:String)->some View {
        Text(s).font(.system(size:16,weight:.semibold)).foregroundStyle(.secondary)
    }

    private func compactRow(_ a:String,_ b:String)->some View {
        HStack {
            Text(a)
            Spacer()
            Text(b).font(.system(size:15,design:.monospaced)).foregroundStyle(.secondary)
        }
        .font(.system(size:16))
        .frame(minHeight:36)
    }

    private var appVersion:String {
        Bundle.main.object(forInfoDictionaryKey:"AppReleaseDisplayVersion") as? String
        ?? Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String
        ?? "1.0"
    }
}

private struct MoonCommunityBanner: View {
    private let moon = Color(red: 0.47, green: 0.31, blue: 1.00)
    private let cyan = Color(red: 0.18, green: 0.84, blue: 1.00)

    var body: some View {
        ZStack(alignment: .leading) {
            LinearGradient(
                colors: [Color(red: 0.035, green: 0.045, blue: 0.11), moon.opacity(0.42)],
                startPoint: .leading,
                endPoint: .trailing
            )

            Circle()
                .fill(cyan.opacity(0.20))
                .frame(width: 150, height: 150)
                .blur(radius: 20)
                .offset(x: 210, y: -28)

            HStack(spacing: 15) {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [cyan, moon], startPoint: .topLeading, endPoint: .bottomTrailing))

                VStack(alignment: .leading, spacing: 5) {
                    Text("MOON X7")
                        .font(.system(size: 22, weight: .black, design: .rounded))
                        .tracking(2)
                    Text("PRIVATE COMMUNITY ACCESS")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(.white.opacity(0.62))
                }
                .foregroundStyle(.white)
            }
            .padding(.horizontal, 20)
        }
    }
}

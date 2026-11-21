import AppKit
import CraCEF
import Perception
import SwiftUI

/// Settings ▸ Profiles ▸ Proxy (not in Arc): the profile's Chromium `proxy` pref (ProxySetting), with
/// the password of an HTTP or HTTPS proxy in the Keychain (ProxyCredentialStore). One card under the
/// profile's own: a menu (macOS settings, no proxy, a server) and, for a server, its address.
struct ProxySettingsCard: View {
    /// nil is Default.
    let profilePath: String?
    private let privacy = NetworkPrivacy.shared
    @State private var editing = false
    @State private var text = ""
    @State private var error: String?

    private enum Choice: Hashable { case system, direct, server, other }

    var body: some View { WithPerceptionTracking {
        let loaded = CraCEFRuntime.loadState(ofProfile: profilePath) == 2
        let current = privacy.proxy(profilePath: profilePath)
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard {
                SettingsCardRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Proxy").font(.system(size: 13))
                        Text(subtitle(current, loaded: loaded))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                } trailing: {
                    Picker("Proxy", selection: choice(current)) {
                        Text("macOS Settings").tag(Choice.system)
                        Text("No Proxy").tag(Choice.direct)
                        Text("Proxy Server…").tag(Choice.server)
                        if Self.choice(of: current) == .other { Text("Set Elsewhere").tag(Choice.other) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!loaded)
                }
                if editing {
                    SettingsCardDivider()
                    SettingsCardRow {
                        TextField("Proxy server", text: $text, prompt: Text("socks5://203.0.113.7:1080 or host:port:user:password"))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .onSubmit { apply() }
                    } trailing: {
                        Button("Cancel") { editing = false; error = nil }
                        Button("Apply") { apply() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else if case .server(let server) = current, ProxyCredentialStore.shared.hasCredentials(profilePath: profilePath, server: server) {
                    SettingsCardDivider()
                    SettingsCardRow {
                        Text("Password").font(.system(size: 13))
                    } trailing: {
                        Button("Change…") { startEditing(current) }
                        Button("Remove") {
                            _ = privacy.setProxy(current, credentials: nil, profilePath: profilePath)
                        }
                    }
                }
            }
            if let error {
                SettingsFootnote(error).foregroundStyle(.red).padding(.top, 6)
            } else {
                SettingsFootnote("When the proxy is down, pages fail instead of loading without it. WebRTC keeps to the proxy too. An HTTP or HTTPS proxy’s user name and password stay in your Keychain: Cra signs the profile in with them, so pages don’t ask. Chromium can’t sign in to SOCKS proxies.")
                    .padding(.top, 6)
            }
        }
    } }

    private func subtitle(_ current: ProxySetting, loaded: Bool) -> String {
        guard loaded else { return "Open a space on this profile to set its proxy." }
        switch current {
        case .system:
            return "Pages follow macOS’s proxy settings" + (privacy.systemProxyOn ? " (a proxy is on)." : " (none is set).")
        case .direct:
            return "Pages connect directly, even when macOS has a proxy."
        case .server(let s):
            let signIn = ProxyCredentialStore.shared.credentials(profilePath: profilePath, host: s.host, port: s.port)
            return s.chromiumServer + (signIn.map { " · signs in as \($0.user)" } ?? "")
        case .other(let s):
            return s + ", set by an extension or Chromium’s settings."
        }
    }

    private static func choice(of setting: ProxySetting) -> Choice {
        switch setting {
        case .system: return .system
        case .direct: return .direct
        case .server: return .server
        case .other: return .other
        }
    }

    private func choice(_ current: ProxySetting) -> Binding<Choice> {
        Binding(get: { editing ? .server : Self.choice(of: current) }, set: { picked in
            error = nil
            switch picked {
            case .system:
                editing = false
                privacy.setProxy(.system, credentials: nil, profilePath: profilePath)
            case .direct:
                editing = false
                privacy.setProxy(.direct, credentials: nil, profilePath: profilePath)
            case .server:
                startEditing(current)
            case .other:
                break
            }
        })
    }

    private func startEditing(_ current: ProxySetting) {
        if case .server(let s) = current { text = s.chromiumServer } else { text = "" }
        error = nil
        editing = true
    }

    private func apply() {
        switch ProxySetting.parse(text) {
        case .invalid(let why):
            error = why
        case .server(let server, let typed):
            // An address typed again without its password keeps the saved one.
            let credentials = typed ?? ProxyCredentialStore.shared.credentials(profilePath: profilePath, host: server.host, port: server.port)
            if privacy.setProxy(.server(server), credentials: credentials, profilePath: profilePath) {
                editing = false
                error = nil
                text = ""
            } else {
                error = "Chromium didn’t take the proxy. An extension or a policy may be setting it."
            }
        }
    }
}

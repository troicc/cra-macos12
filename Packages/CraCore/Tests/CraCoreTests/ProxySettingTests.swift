import CraCore
import Foundation
import Testing

/// Settings ▸ Profiles ▸ Proxy (not in Arc): a profile's Chromium `proxy` pref, and the WebRTC
/// policy that keeps a page behind it from learning this Mac's own address.
struct ProxySettingTests {
    private func server(_ input: String) -> (ProxyServer, ProxyCredentials?)? {
        if case .server(let s, let c) = ProxySetting.parse(input) { return (s, c) }
        return nil
    }

    private func invalid(_ input: String) -> Bool {
        if case .invalid = ProxySetting.parse(input) { return true }
        return false
    }

    @Test func readsTheFormsProxySellersHandOut() {
        #expect(server("socks5://203.0.113.7:1080")?.0 == ProxyServer(scheme: .socks5, host: "203.0.113.7", port: 1080))
        #expect(server("socks://203.0.113.7:1080")?.0.scheme == .socks5)
        #expect(server("  HTTP://Proxy.Example:8080/ ")?.0 == ProxyServer(scheme: .http, host: "proxy.example", port: 8080))
        // No scheme is HTTP, the default port with no port.
        #expect(server("proxy.example:3128")?.0 == ProxyServer(scheme: .http, host: "proxy.example", port: 3128))
        #expect(server("https://proxy.example")?.0.port == 443)
        #expect(server("socks5://proxy.example")?.0.port == 1080)
        // Credentials in the address, or after it.
        let inline = server("http://user%40mail:p%3Ass@proxy.example:8080")
        #expect(inline?.0 == ProxyServer(scheme: .http, host: "proxy.example", port: 8080))
        #expect(inline?.1 == ProxyCredentials(user: "user@mail", password: "p:ss"))
        #expect(server("user:pass@10.0.0.2:8000")?.1 == ProxyCredentials(user: "user", password: "pass"))
        let trailing = server("gate.example:7777:customer-abc:secret")
        #expect(trailing?.0 == ProxyServer(scheme: .http, host: "gate.example", port: 7777))
        #expect(trailing?.1 == ProxyCredentials(user: "customer-abc", password: "secret"))
        // IPv6 keeps its brackets in Chromium's form.
        let v6 = server("socks5://[2001:db8::1]:1080")?.0
        #expect(v6?.host == "2001:db8::1")
        #expect(v6?.chromiumServer == "socks5://[2001:db8::1]:1080")
    }

    @Test func refusesWhatChromiumCantUse() {
        #expect(invalid(""))
        #expect(invalid("ftp://proxy.example:21"))
        #expect(invalid("proxy.example:port"))
        #expect(invalid("proxy.example:0"))
        #expect(invalid("proxy.example:70000"))
        #expect(invalid("proxy example:8080"))
        #expect(invalid("bad_host!:8080"))
        #expect(invalid("a:b:c"))
        // Chromium has no SOCKS authentication: the proxy would turn every page away.
        #expect(invalid("socks5://user:pass@proxy.example:1080"))
        #expect(invalid("socks4://user:pass@proxy.example:1080"))
        guard case .invalid(let why) = ProxySetting.parse("socks5://u:p@h.example:1") else { Issue.record("accepted"); return }
        #expect(why.contains("http://"))
    }

    @Test func writesAndReadsChromiumsPref() throws {
        let s = ProxyServer(scheme: .socks5, host: "203.0.113.7", port: 1080)
        let json = try #require(ProxySetting.server(s).prefJSON)
        #expect(json == #"{"mode":"fixed_servers","server":"socks5://203.0.113.7:1080"}"#)
        #expect(ProxySetting(prefJSON: json) == .server(s))
        #expect(ProxySetting.direct.prefJSON == #"{"mode":"direct"}"#)
        #expect(ProxySetting(prefJSON: #"{"mode":"direct"}"#) == .direct)
        // System is the pref's default: Cra resets it rather than writing it.
        #expect(ProxySetting.system.prefJSON == nil)
        #expect(ProxySetting(prefJSON: #"{"mode":"system"}"#) == .system)
        #expect(ProxySetting(prefJSON: nil) == .system)
        #expect(ProxySetting(prefJSON: "garbage") == .system)
        // What an extension or chrome://settings may set is shown, never rewritten.
        #expect(ProxySetting(prefJSON: #"{"mode":"pac_script","pac_url":"http://wpad/proxy.pac"}"#) == .other("PAC script http://wpad/proxy.pac"))
        #expect(ProxySetting(prefJSON: #"{"mode":"auto_detect"}"#) == .other("Auto-detect"))
        #expect(ProxySetting(prefJSON: #"{"mode":"fixed_servers","server":"http=a.example:80;https=b.example:443"}"#)
                == .other("http=a.example:80;https=b.example:443"))
        #expect(ProxySetting(prefJSON: #"{"mode":"fixed_servers","server":"a.example:3128"}"#)
                == .server(ProxyServer(scheme: .http, host: "a.example", port: 3128)))
        #expect(ProxySetting.other("Auto-detect").prefJSON == nil)
    }

    @Test func knowsWhetherPagesGoThroughAProxy() {
        #expect(ProxySetting.system.isProxied == nil)
        #expect(ProxySetting.direct.isProxied == false)
        #expect(ProxySetting.server(ProxyServer(scheme: .http, host: "h.example", port: 1)).isProxied == true)
        #expect(ProxySetting.other("Auto-detect").isProxied == true)
    }

    @Test func readsMacOSProxySettings() {
        #expect(!SystemProxy.isOn([:]))
        #expect(!SystemProxy.isOn(["HTTPEnable": NSNumber(value: 0), "ExceptionsList": ["*.local"]]))
        #expect(SystemProxy.isOn(["HTTPEnable": NSNumber(value: 1), "HTTPProxy": "127.0.0.1", "HTTPPort": NSNumber(value: 7890)]))
        #expect(SystemProxy.isOn(["SOCKSEnable": NSNumber(value: 1)]))
        #expect(SystemProxy.isOn(["ProxyAutoConfigEnable": true]))
    }

    /// The leak: with an HTTP or SOCKS proxy, a STUN request over UDP went straight out and the page
    /// read this Mac's real public address from the answer.
    @Test func keepsWebRTCBehindAProxy() {
        let proxy = ProxySetting.server(ProxyServer(scheme: .socks5, host: "203.0.113.7", port: 1080))
        #expect(WebRTCIPHandling.policy(proxy: proxy, systemProxyOn: false, alwaysProxied: false) == "disable_non_proxied_udp")
        // macOS's own proxy (Clash and the like set it) counts too.
        #expect(WebRTCIPHandling.policy(proxy: .system, systemProxyOn: true, alwaysProxied: false) == "disable_non_proxied_udp")
        #expect(WebRTCIPHandling.policy(proxy: .other("PAC script"), systemProxyOn: false, alwaysProxied: false) == "disable_non_proxied_udp")
        // Without one, the local address stays hidden and calls keep UDP.
        #expect(WebRTCIPHandling.policy(proxy: .system, systemProxyOn: false, alwaysProxied: false) == "default_public_interface_only")
        #expect(WebRTCIPHandling.policy(proxy: .direct, systemProxyOn: true, alwaysProxied: false) == "default_public_interface_only")
        // Privacy ▸ "Keep WebRTC behind the proxy" holds it there either way.
        #expect(WebRTCIPHandling.policy(proxy: .direct, systemProxyOn: false, alwaysProxied: true) == "disable_non_proxied_udp")
    }

    @Test func keysCredentialsByServer() {
        #expect(ProxyServer(scheme: .http, host: "Gate.Example", port: 7777).credentialKey == "gate.example:7777")
        #expect(ProxyServer.Scheme.http.takesCredentials && ProxyServer.Scheme.https.takesCredentials)
        #expect(!ProxyServer.Scheme.socks5.takesCredentials)
    }
}

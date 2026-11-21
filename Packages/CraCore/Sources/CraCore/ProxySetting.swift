import Foundation

/// A proxy server as Chromium names it in a profile's `proxy` pref: `socks5://203.0.113.7:1080`.
public struct ProxyServer: Equatable, Sendable {
    public enum Scheme: String, CaseIterable, Sendable {
        case http, https, socks4, socks5

        /// What the Proxy row's menu calls it.
        public var label: String {
            switch self {
            case .http: return "HTTP"
            case .https: return "HTTPS"
            case .socks4: return "SOCKS4"
            case .socks5: return "SOCKS5"
            }
        }

        /// Chromium asks for a user name and password only for HTTP and HTTPS proxies: it has no
        /// SOCKS authentication (net/socket/socks5_client_socket.cc sends "no authentication" only).
        public var takesCredentials: Bool { self == .http || self == .https }

        var defaultPort: Int {
            switch self {
            case .http: return 80
            case .https: return 443
            case .socks4, .socks5: return 1080
            }
        }
    }

    public var scheme: Scheme
    /// A name or an address, IPv6 without brackets.
    public var host: String
    public var port: Int

    public init(scheme: Scheme, host: String, port: Int) {
        self.scheme = scheme
        self.host = host
        self.port = port
    }

    /// The pref's `server` value, and what the Proxy row shows.
    public var chromiumServer: String {
        let h = host.contains(":") ? "[\(host)]" : host
        return "\(scheme.rawValue)://\(h):\(port)"
    }

    /// The Keychain account its credentials are kept under, with the profile in front.
    public var credentialKey: String { "\(host.lowercased()):\(port)" }
}

/// A user name and password for an HTTP or HTTPS proxy. Kept in the Keychain, never in a pref.
public struct ProxyCredentials: Equatable, Sendable {
    public var user: String
    public var password: String

    public init(user: String, password: String) {
        self.user = user
        self.password = password
    }
}

/// A profile's proxy (Settings ▸ Profiles ▸ Proxy), not in Arc: Chromium's per-profile `proxy`
/// pref (proxy_config::prefs::kProxy), the dictionary chrome.proxy and `--proxy-server` set. It
/// lives in the profile's Preferences file, so the proxy is in place before the first page of the
/// next launch loads. With a fixed server Chromium never falls back to a direct connection: a
/// proxy that is down fails the page (ERR_PROXY_CONNECTION_FAILED) instead of showing this Mac's
/// address. Only loopback addresses go around it, as Chromium always does.
public enum ProxySetting: Equatable, Sendable {
    /// Chromium's default: macOS's proxy settings (System Settings ▸ Network, or what Clash or
    /// another app sets there).
    case system
    /// No proxy, even when macOS has one.
    case direct
    /// One server for everything.
    case server(ProxyServer)
    /// Something only Chromium's pages or an extension set: a PAC script, auto-detect, or
    /// per-scheme rules. Shown, not edited. The string is what the Proxy row says about it.
    case other(String)

    public static let pref = "proxy"

    /// The pref as CraCEFRuntime.preference returns it: `{"mode":"fixed_servers","server":"…"}`.
    /// Nil or anything unreadable is Chromium's default, the system's proxy.
    public init(prefJSON: String?) {
        guard let data = prefJSON?.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let mode = dict["mode"] as? String else { self = .system; return }
        switch mode {
        case "system": self = .system
        case "direct": self = .direct
        case "fixed_servers":
            let rules = (dict["server"] as? String) ?? ""
            if let server = Self.singleServer(rules) { self = .server(server) } else { self = .other(rules.isEmpty ? "Fixed servers" : rules) }
        case "pac_script":
            let url = (dict["pac_url"] as? String) ?? ""
            self = .other(url.isEmpty ? "PAC script" : "PAC script " + url)
        case "auto_detect": self = .other("Auto-detect")
        default: self = .other(mode)
        }
    }

    /// What CraCEFRuntime.setPreference takes. Nil for .system: the pref is reset, so the profile
    /// follows Chromium's default again. Nil for .other, which Cra doesn't write.
    public var prefJSON: String? {
        switch self {
        case .system, .other: return nil
        case .direct: return #"{"mode":"direct"}"#
        case .server(let s):
            let object: [String: Any] = ["mode": "fixed_servers", "server": s.chromiumServer]
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    /// Whether pages of this profile go through a proxy that Cra can see from the pref alone.
    /// Nil for .system: it depends on macOS's settings (SystemProxy.isOn).
    public var isProxied: Bool? {
        switch self {
        case .system: return nil
        case .direct: return false
        case .server, .other: return true
        }
    }

    /// The Proxy row's one line.
    public var summary: String {
        switch self {
        case .system: return "Use macOS proxy settings"
        case .direct: return "No proxy"
        case .server(let s): return s.chromiumServer
        case .other(let s): return s
        }
    }

    /// A proxy as people paste it, in the forms proxy sellers hand them out:
    /// `socks5://host:port`, `http://user:pass@host:port`, `user:pass@host:port`, `host:port` and
    /// `host:port:user:pass`. Without a scheme it is HTTP. A user name and password with SOCKS is
    /// refused: Chromium can't send them, and the proxy would turn every page away.
    public enum Parsed: Equatable, Sendable {
        case server(ProxyServer, ProxyCredentials?)
        case invalid(String)
    }

    public static func parse(_ input: String, defaultScheme: ProxyServer.Scheme = .http) -> Parsed {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }) else {
            return .invalid("Enter the proxy like socks5://203.0.113.7:1080 or http://user:password@proxy.example:8080.")
        }
        var scheme = defaultScheme
        if let range = text.range(of: "://") {
            let name = text[..<range.lowerBound].lowercased()
            guard let s = ProxyServer.Scheme(rawValue: name == "socks" ? "socks5" : name) else {
                return .invalid("Cra knows HTTP, HTTPS, SOCKS4 and SOCKS5 proxies, not “\(name)”.")
            }
            scheme = s
            text = String(text[range.upperBound...])
        }
        while text.hasSuffix("/") { text.removeLast() }
        var credentials: ProxyCredentials?
        if let at = text.lastIndex(of: "@") {
            let userInfo = String(text[..<at])
            text = String(text[text.index(after: at)...])
            let parts = userInfo.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let user = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let password = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? String(parts[1])) : ""
            guard !user.isEmpty else { return .invalid("The user name before “@” is empty.") }
            credentials = ProxyCredentials(user: user, password: password)
        }
        let hostPort: (host: String, port: Int?)
        if text.hasPrefix("[") {
            // [2001:db8::1]:1080
            guard let close = text.firstIndex(of: "]") else { return .invalid("The IPv6 address has no closing “]”.") }
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if rest.isEmpty { hostPort = (host, nil) }
            else if rest.hasPrefix(":"), let p = Int(rest.dropFirst()) { hostPort = (host, p) }
            else { return .invalid("Put the port after the address, like [2001:db8::1]:1080.") }
        } else {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            switch parts.count {
            case 1: hostPort = (parts[0], nil)
            case 2:
                guard let p = Int(parts[1]) else { return .invalid("“\(parts[1])” isn’t a port number.") }
                hostPort = (parts[0], p)
            case 4 where credentials == nil:
                // host:port:user:pass
                guard let p = Int(parts[1]) else { return .invalid("“\(parts[1])” isn’t a port number.") }
                guard !parts[2].isEmpty else { return .invalid("The user name is empty.") }
                credentials = ProxyCredentials(user: parts[2], password: parts[3])
                hostPort = (parts[0], p)
            default:
                return .invalid("Enter the proxy like socks5://203.0.113.7:1080 or http://user:password@proxy.example:8080.")
            }
        }
        let host = hostPort.host.lowercased()
        guard isHost(host) else { return .invalid("“\(hostPort.host)” isn’t a host name or an IP address.") }
        let port = hostPort.port ?? scheme.defaultPort
        guard (1...65535).contains(port) else { return .invalid("The port has to be between 1 and 65535.") }
        if credentials != nil, !scheme.takesCredentials {
            return .invalid("Chromium can’t sign in to a \(scheme.label) proxy. Most proxies with a password take HTTP too: try http:// with the same address.")
        }
        return .server(ProxyServer(scheme: scheme, host: host, port: port), credentials)
    }

    /// `socks5://h:1080` or `h:8080` (HTTP). Rules for several schemes ("http=a:1;https=b:2") or a
    /// list of fallbacks are not one server.
    static func singleServer(_ rules: String) -> ProxyServer? {
        let rule = rules.trimmingCharacters(in: .whitespaces)
        guard !rule.isEmpty, !rule.contains("="), !rule.contains(";"), !rule.contains(","), !rule.contains(" ") else { return nil }
        guard case .server(let server, nil) = parse(rule) else { return nil }
        return server
    }

    static func isHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        if host.contains(":") {
            // IPv6: hex digits, colons and an embedded IPv4 tail.
            return host.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." } && host.filter { $0 == ":" }.count >= 2
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" }
        }
    }
}

/// macOS's own proxy settings, which a profile on .system follows (CFNetworkCopySystemProxySettings).
public enum SystemProxy {
    /// Whether the settings send web traffic anywhere but straight out: an HTTP, HTTPS or SOCKS
    /// proxy, a PAC file or proxy auto-discovery that is switched on.
    public static func isOn(_ settings: [String: Any]) -> Bool {
        let switches = ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"]
        return switches.contains { key in
            if let n = settings[key] as? NSNumber { return n.intValue != 0 }
            if let b = settings[key] as? Bool { return b }
            return false
        }
    }
}

/// Chromium's WebRTC IP handling policy (`webrtc.ip_handling_policy`), which decides which
/// addresses a page's RTCPeerConnection may learn and offer.
///
/// Cra always hides the local address (default_public_interface_only). That still lets a STUN
/// request over UDP go straight out, and UDP never goes through an HTTP or SOCKS proxy, so a page
/// behind a proxy learned this Mac's real public address from the STUN answer. Behind a proxy,
/// WebRTC keeps to the proxy instead (disable_non_proxied_udp): TCP through the proxy, UDP only if
/// the proxy carries it.
public enum WebRTCIPHandling {
    public static let pref = "webrtc.ip_handling_policy"
    public static let publicInterfaceOnly = "default_public_interface_only"
    public static let proxiedOnly = "disable_non_proxied_udp"

    /// `alwaysProxied` is Privacy ▸ "Keep WebRTC behind the proxy": proxied-only even without a
    /// proxy, for a proxy Cra can't see (one in a router), at the cost of calls that need UDP.
    public static func policy(proxy: ProxySetting, systemProxyOn: Bool, alwaysProxied: Bool) -> String {
        if alwaysProxied { return proxiedOnly }
        return (proxy.isProxied ?? systemProxyOn) ? proxiedOnly : publicInterfaceOnly
    }
}

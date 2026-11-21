import AppKit
import CFNetwork
import CraCEF
import Perception
import Security

/// Settings ▸ Profiles ▸ Proxy's user names and passwords, in the login Keychain (service
/// "Cra Proxy", account "<profile folder> <host>:<port>"), never in a pref or settings.json.
/// Chromium asks from its IO thread, so this keeps a copy in memory behind a lock and reads the
/// Keychain once, before Chromium starts: a Keychain prompt (an ad-hoc signed build asks after
/// each update) must not hold up the network.
final class ProxyCredentialStore: @unchecked Sendable {
    static let shared = ProxyCredentialStore()
    static let service = "Cra Proxy"

    private let lock = NSLock()
    private var cache: [String: ProxyCredentials] = [:]

    static func account(profilePath: String?, server: String) -> String {
        (profilePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Default") + " " + server
    }

    /// What CraCEFRuntime.setProxyCredentialsHandler takes: made here, outside the main actor,
    /// because Chromium calls it from its IO thread.
    static func chromiumHandler() -> (String?, String, Int) -> [String]? {
        { path, host, port in
            ProxyCredentialStore.shared.credentials(profilePath: path, host: host, port: port).map { [$0.user, $0.password] }
        }
    }

    func credentials(profilePath: String?, host: String, port: Int) -> ProxyCredentials? {
        let key = Self.account(profilePath: profilePath, server: "\(host.lowercased()):\(port)")
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    func hasCredentials(profilePath: String?, server: ProxyServer) -> Bool {
        credentials(profilePath: profilePath, host: server.host, port: server.port) != nil
    }

    /// Nil removes them. `persist: false` keeps them in memory only (cra://debug in a test copy).
    func save(_ credentials: ProxyCredentials?, profilePath: String?, server: ProxyServer, persist: Bool = true) {
        let account = Self.account(profilePath: profilePath, server: server.credentialKey)
        lock.lock()
        cache[account] = credentials
        lock.unlock()
        guard persist else { return }
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(match as CFDictionary)
        guard let credentials, let data = try? JSONEncoder().encode([credentials.user, credentials.password]) else { return }
        var add = match
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Cra proxy \(server.credentialKey)"
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { CraLog.note("proxy: Keychain refused the password (\(status))") }
    }

    /// Every saved item, read into memory. Called once from main.swift before Chromium starts.
    func loadAll() {
        let list: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                   kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnAttributes as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(list as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return }
        var loaded: [String: ProxyCredentials] = [:]
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else { continue }
            let one: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                      kSecAttrAccount as String: account, kSecReturnData as String: true,
                                      kSecMatchLimit as String: kSecMatchLimitOne]
            var data: CFTypeRef?
            guard SecItemCopyMatching(one as CFDictionary, &data) == errSecSuccess, let d = data as? Data,
                  let pair = try? JSONDecoder().decode([String].self, from: d), pair.count == 2 else { continue }
            loaded[account] = ProxyCredentials(user: pair[0], password: pair[1])
        }
        lock.lock()
        cache.merge(loaded) { current, _ in current }
        lock.unlock()
    }
}

/// The network side of Settings ▸ Profiles ▸ Proxy and Settings ▸ Privacy ▸ "Exit IP" (not in Arc):
/// each profile's proxy, the WebRTC policy that follows it, the exit address in the menu bar and
/// the time zone pages see. The decisions are CraCore's (ProxySetting, WebRTCIPHandling, ExitIPInfo,
/// ExitTimeZone); this wires them to Chromium and macOS.
@MainActor
@Perceptible
final class NetworkPrivacy {
    static let shared = NetworkPrivacy()

    /// Whether macOS sends web traffic through a proxy (System Settings, or Clash and the like).
    private(set) var systemProxyOn = false
    /// Each checked profile's exit address, by profile path ("" is Default).
    private(set) var states: [String: ExitIPState] = [:]
    /// The last "Exit IP changed from … to …" per profile, with when.
    private(set) var lastChange: [String: (text: String, at: Date)] = [:]
    /// Bumped when a profile's proxy changes, so Settings reads it again.
    private(set) var proxyGeneration = 0

    @PerceptionIgnored private weak var store: SidebarStore?
    @PerceptionIgnored private var started = false
    @PerceptionIgnored private var clock: Scheduler = LiveScheduler.shared
    @PerceptionIgnored private var checkTimer: ScheduledWork?
    @PerceptionIgnored private var systemProxyTimer: ScheduledWork?
    @PerceptionIgnored private var failures: [String: Int] = [:]
    @PerceptionIgnored private var inFlight: Set<String> = []
    @PerceptionIgnored private var menuItem: ExitIPMenuItem?
    /// The profile of the space in front (nil is Default); set by AppDelegate.
    @PerceptionIgnored var frontProfile: () -> String? = { nil }
    @PerceptionIgnored var openPrivacySettings: () -> Void = {}

    private init() {}

    private static func key(_ path: String?) -> String { path ?? "" }

    /// From main.swift, before Chromium starts: the WebRTC policy and proxy sign-in must be in place
    /// before the first profile loads and its first page asks for anything.
    func install(store: SidebarStore) {
        self.store = store
        ProxyCredentialStore.shared.loadAll()
        systemProxyOn = Self.readSystemProxy()
        CraCEFRuntime.setWebRTCPolicyResolver { json in
            MainActor.assumeIsolated { NetworkPrivacy.shared.webRTCPolicy(proxyJSON: json) }
        }
        CraCEFRuntime.setProxyCredentialsHandler(ProxyCredentialStore.chromiumHandler())
        for (key, info) in Self.cachedInfos() { states[key] = .known(info) }
    }

    /// From AppDelegate's bootstrap: settings, macOS's proxy and the exit address, live.
    func start(clock: Scheduler) {
        guard !started, let store else { return }
        started = true
        self.clock = clock
        observeChanges(of: { [store] in store.settings.webRTCAlwaysProxied }) { _ in CraCEFRuntime.refreshWebRTCPolicy() }
        observeChanges(of: { [store] in store.settings.exitIPInMenuBar }) { [weak self] on in self?.showMenuItem(on) }
        observeChanges(of: { [store] in [store.settings.exitIPInMenuBar, store.settings.matchTimeZoneToExitIP] }) { [weak self] _ in
            self?.restartChecks()
        }
        observeChanges(of: { [store] in store.settings.exitIPLookupURL }) { [weak self] _ in self?.checkAll() }
        CraCEFRuntime.setProxyChangeHandler {
            MainActor.assumeIsolated {
                NetworkPrivacy.shared.proxyGeneration += 1
                NetworkPrivacy.shared.checkAll()
            }
        }
        // CFNetwork has no change notification: macOS's proxy is read every few seconds, which costs
        // a dictionary copy.
        systemProxyTimer = clock.every(3) { NetworkPrivacy.shared.pollSystemProxy() }
    }

    // MARK: WebRTC

    func webRTCPolicy(proxyJSON: String?) -> String {
        WebRTCIPHandling.policy(proxy: ProxySetting(prefJSON: proxyJSON), systemProxyOn: systemProxyOn,
                                alwaysProxied: store?.settings.webRTCAlwaysProxied ?? false)
    }

    static func readSystemProxy() -> Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return false }
        return SystemProxy.isOn(settings)
    }

    private func pollSystemProxy() {
        let on = Self.readSystemProxy()
        guard on != systemProxyOn else { return }
        systemProxyOn = on
        CraLog.note("proxy: macOS proxy \(on ? "on" : "off")")
        CraCEFRuntime.refreshWebRTCPolicy()
        checkAll()
    }

    // MARK: Proxy

    /// A profile's proxy as Chromium holds it now (nil profilePath is Default). .system until it loads.
    func proxy(profilePath: String?) -> ProxySetting {
        _ = proxyGeneration
        return ProxySetting(prefJSON: CraCEFRuntime.preference(ProxySetting.pref, forProfile: profilePath))
    }

    /// Writes the profile's `proxy` pref, and the password for a server (nil credentials remove any).
    /// False when Chromium refused it: the profile hasn't loaded, or a policy holds the pref.
    @discardableResult
    func setProxy(_ setting: ProxySetting, credentials: ProxyCredentials?, profilePath: String?, persistCredentials: Bool = true) -> Bool {
        if case .server(let server) = setting {
            ProxyCredentialStore.shared.save(credentials, profilePath: profilePath, server: server, persist: persistCredentials)
        }
        let ok: Bool
        if let json = setting.prefJSON {
            ok = CraCEFRuntime.setPreference(ProxySetting.pref, json: json, forProfile: profilePath)
        } else {
            ok = CraCEFRuntime.resetPreference(ProxySetting.pref, forProfile: profilePath)
        }
        CraLog.note("proxy: \(ok ? "set" : "refused") \(Self.logSummary(setting))\(credentials == nil ? "" : " with a password")")
        proxyGeneration += 1
        return ok
    }

    /// The log names the kind of proxy, never its address.
    private static func logSummary(_ setting: ProxySetting) -> String {
        switch setting {
        case .system: return "system"
        case .direct: return "direct"
        case .server(let s): return s.scheme.rawValue
        case .other: return "other"
        }
    }

    // MARK: Exit IP

    private var checking: Bool {
        guard let s = store?.settings else { return false }
        return s.exitIPInMenuBar || s.matchTimeZoneToExitIP
    }

    private func restartChecks() {
        checkTimer?.cancel()
        checkTimer = nil
        applyTimeZones()
        guard checking else { return }
        checkTimer = clock.every(ExitIPLookup.interval) { NetworkPrivacy.shared.checkAll() }
        checkAll()
    }

    /// Default and every profile Chromium has loaded.
    private var loadedProfiles: [String?] {
        guard let store else { return [nil] }
        let others = store.profiles.compactMap { store.profilePath(profile: $0.id) }.filter { CraCEFRuntime.loadState(ofProfile: $0) == 2 }
        return [nil] + others
    }

    func checkAll() {
        guard checking else { return }
        for path in loadedProfiles { check(path) }
    }

    func check(_ path: String?) {
        let key = Self.key(path)
        guard checking, !inFlight.contains(key), let store, let url = ExitIPLookup.url(store.settings.exitIPLookupURL) else { return }
        inFlight.insert(key)
        if states[key] == nil { states[key] = .checking }
        menuItem?.update()
        CraCEFRuntime.fetchURL(url.absoluteString, headers: ["Accept": "application/json"], profilePath: path) { status, _, _, body in
            MainActor.assumeIsolated { NetworkPrivacy.shared.finish(key: key, path: path, status: status, body: body) }
        }
    }

    private func finish(key: String, path: String?, status: Int, body: String) {
        inFlight.remove(key)
        let info = (200..<300).contains(status) ? ExitIPInfo.parse(body) : nil
        failures[key] = info == nil ? (failures[key] ?? 0) + 1 : 0
        let old = knownInfo(key)
        let next = ExitIPState.after(states[key] ?? .unknown, result: info, failuresInARow: failures[key] ?? 0)
        if next != states[key] { states[key] = next }
        let name = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Default"
        if let info {
            if let change = ExitIPState.change(from: old, to: info) {
                lastChange[key] = (change, clock.now)
                CraLog.note("exit ip \(name): changed")
            }
            Self.cache(info, key: key)
        } else if case .failed = next {
            CraLog.note("exit ip \(name): failed (HTTP \(status))")
        }
        applyTimeZone(path: path)
        menuItem?.update()
    }

    func knownInfo(_ key: String) -> ExitIPInfo? {
        switch states[key] {
        case .known(let info): return info
        case .failed(let last): return last
        default: return nil
        }
    }

    /// The front space's profile, for the menu bar.
    var frontState: ExitIPState { states[Self.key(frontProfile())] ?? .unknown }

    // MARK: Time zone

    private func applyTimeZones() {
        var paths = Set(loadedProfiles.map(Self.key))
        paths.formUnion(states.keys)
        for key in paths { applyTimeZone(path: key.isEmpty ? nil : key) }
    }

    private func applyTimeZone(path: String?) {
        let zone = ExitTimeZone.override(enabled: store?.settings.matchTimeZoneToExitIP ?? false, info: knownInfo(Self.key(path)))
        if CraCEFRuntime.timeZoneOverride(forProfile: path) != zone {
            CraCEFRuntime.setTimeZoneOverride(zone, forProfile: path)
            CraLog.note("time zone \(path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Default"): \(zone ?? "the Mac's")")
        }
    }

    // MARK: Last known addresses

    /// The last address of each profile, so the time zone is right for the pages restored at
    /// launch, before the first check answers.
    private static let cacheKey = "exitIPLastKnown"

    private static func cachedInfos() -> [String: ExitIPInfo] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return [:] }
        return (try? JSONDecoder().decode([String: ExitIPInfo].self, from: data)) ?? [:]
    }

    private static func cache(_ info: ExitIPInfo, key: String) {
        var all = cachedInfos()
        guard all[key] != info else { return }
        all[key] = info
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: cacheKey) }
    }

    // MARK: Menu bar

    private func showMenuItem(_ on: Bool) {
        if on, menuItem == nil { menuItem = ExitIPMenuItem(privacy: self) }
        if !on { menuItem?.remove(); menuItem = nil }
        menuItem?.update()
    }

    /// Called when the front space changes.
    func frontChanged() {
        if case .unknown = frontState { check(frontProfile()) }
        menuItem?.update()
    }

    /// cra://debug?exitIP=show: what the menu would say, address included.
    func debugDescription(profilePath: String?) -> String {
        let key = Self.key(profilePath)
        let state: String
        switch states[key] ?? .unknown {
        case .unknown: state = "unknown"
        case .checking: state = "checking"
        case .known(let i): state = "known \(i.ip) \(i.countryCode ?? "-") \(i.timeZone ?? "-")"
        case .failed(let last): state = "failed last=\(last?.ip ?? "-")"
        }
        let zone = CraCEFRuntime.timeZoneOverride(forProfile: profilePath) ?? "-"
        return "exit ip \(key.isEmpty ? "Default" : URL(fileURLWithPath: key).lastPathComponent): \(state) tz=\(zone) systemProxy=\(systemProxyOn ? 1 : 0)"
    }
}

/// Privacy ▸ "Show the exit IP in the menu bar": the front space's exit address with its country's
/// flag, and a menu with where it is, its network, the profile's proxy and WebRTC policy.
@MainActor
final class ExitIPMenuItem: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private unowned let privacy: NetworkPrivacy

    init(privacy: NetworkPrivacy) {
        self.privacy = privacy
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.setAccessibilityLabel("Exit IP")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    func remove() { NSStatusBar.system.removeStatusItem(item) }

    func update() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let title: String
        var color: NSColor?
        switch privacy.frontState {
        case .unknown, .checking: title = "Exit IP…"
        case .known(let info): title = info.menuTitle
        case .failed(let last):
            title = "⚠︎ " + (last?.ip ?? "Offline")
            color = .systemRed
        }
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if let color { attributes[.foregroundColor] = color }
        item.button?.attributedTitle = NSAttributedString(string: title, attributes: attributes)
        item.button?.toolTip = "The address websites see this space come from"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let path = privacy.frontProfile()
        let info = privacy.knownInfo(path ?? "")
        func line(_ text: String) {
            let i = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i)
        }
        switch privacy.frontState {
        case .failed: line("Can’t reach the lookup service: the proxy or the network is down.")
        case .unknown, .checking: line("Checking…")
        case .known: break
        }
        if let info {
            menu.addItem(BlockMenuItem(title: "Copy \(info.ip)") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(info.ip, forType: .string)
            })
            if !info.place.isEmpty { line("Location: " + info.place) }
            if let org = info.organization { line("Network: " + org) }
            if let zone = info.timeZone {
                let matched = CraCEFRuntime.timeZoneOverride(forProfile: path) == zone
                line("Time zone: " + zone + (matched ? " (pages use it)" : ""))
            }
        }
        if let change = privacy.lastChange[path ?? ""] {
            line(change.text + " (" + change.at.formatted(date: .omitted, time: .shortened) + ")")
        }
        menu.addItem(.separator())
        let proxy = privacy.proxy(profilePath: path)
        let viaSystem = proxy == .system ? (privacy.systemProxyOn ? " (on)" : " (none set)") : ""
        line("Proxy: " + proxy.summary + viaSystem)
        let policy = privacy.webRTCPolicy(proxyJSON: CraCEFRuntime.preference(ProxySetting.pref, forProfile: path))
        line(policy == WebRTCIPHandling.proxiedOnly ? "WebRTC: kept behind the proxy" : "WebRTC: local address hidden")
        menu.addItem(.separator())
        menu.addItem(BlockMenuItem(title: "Check Now") { [privacy] in privacy.check(path) })
        menu.addItem(BlockMenuItem(title: "Privacy Settings…") { [privacy] in privacy.openPrivacySettings() })
    }
}

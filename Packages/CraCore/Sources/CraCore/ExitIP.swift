import Foundation

/// The address websites see a profile come from, and where that address is (Privacy ▸ "Show the
/// exit IP in the menu bar", not in Arc). Cra asks a lookup service through the profile itself,
/// proxy and all, so the answer is the one a page would get. Only that service sees the request,
/// and it sees the exit address, which every site sees anyway.
public struct ExitIPInfo: Equatable, Codable, Sendable {
    public var ip: String
    /// ISO 3166-1 alpha-2, upper case.
    public var countryCode: String?
    public var region: String?
    public var city: String?
    /// The network: "AS2516 KDDI CORPORATION".
    public var organization: String?
    /// An IANA name Foundation knows: "Asia/Tokyo".
    public var timeZone: String?
    public var latitude: Double?
    public var longitude: Double?

    public init(ip: String, countryCode: String? = nil, region: String? = nil, city: String? = nil, organization: String? = nil,
                timeZone: String? = nil, latitude: Double? = nil, longitude: Double? = nil) {
        self.ip = ip
        self.countryCode = countryCode
        self.region = region
        self.city = city
        self.organization = organization
        self.timeZone = timeZone
        self.latitude = latitude
        self.longitude = longitude
    }

    /// A lookup service's answer. Reads the JSON of ipinfo.io, ipapi.co, ip-api.com, ipwho.is and
    /// ifconfig.co, or a bare address (api.ipify.org, icanhazip.com). Nil for anything without a
    /// valid address in it, or an answer that says the lookup failed.
    public static func parse(_ body: String) -> ExitIPInfo? {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if isIPAddress(text) { return ExitIPInfo(ip: text) }
        guard let data = text.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let status = dict["status"] as? String, status != "success" { return nil }  // ip-api.com
        if let success = dict["success"] as? Bool, !success { return nil }  // ipwho.is
        if dict["error"] != nil, dict["ip"] == nil { return nil }
        func string(_ keys: String...) -> String? {
            for key in keys {
                if let s = dict[key] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s.trimmingCharacters(in: .whitespaces) }
            }
            return nil
        }
        func number(_ keys: String...) -> Double? {
            for key in keys {
                if let n = dict[key] as? NSNumber { return n.doubleValue }
                if let s = dict[key] as? String, let d = Double(s) { return d }
            }
            return nil
        }
        guard let ip = string("ip", "query"), isIPAddress(ip) else { return nil }
        var info = ExitIPInfo(ip: ip)
        let code = string("country_code", "countryCode", "country_iso") ?? string("country").flatMap { $0.count == 2 ? $0 : nil }
        info.countryCode = code.flatMap { c in c.count == 2 && c.allSatisfy { $0.isASCII && $0.isLetter } ? c.uppercased() : nil }
        info.region = string("region", "regionName", "region_name")
        info.city = string("city")
        let connection = dict["connection"] as? [String: Any]
        let asn = string("asn", "as") ?? (connection?["asn"] as? NSNumber).map { "AS\($0.intValue)" }
        let org = string("org", "asn_org", "isp") ?? (connection?["org"] as? String) ?? (connection?["isp"] as? String)
        if let asn = asn, let org = org, !org.hasPrefix("AS"), asn.hasPrefix("AS"), !asn.contains(" ") { info.organization = asn + " " + org }
        else { info.organization = org ?? asn }
        let zone = string("timezone", "time_zone") ?? ((dict["timezone"] as? [String: Any])?["id"] as? String)
        info.timeZone = zone.flatMap { TimeZone(identifier: $0) != nil ? $0 : nil }
        if let loc = string("loc") {
            let parts = loc.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2 { info.latitude = parts[0]; info.longitude = parts[1] }
        } else {
            info.latitude = number("latitude", "lat")
            info.longitude = number("longitude", "lon")
        }
        if let lat = info.latitude, let lon = info.longitude, !((-90...90).contains(lat) && (-180...180).contains(lon)) {
            info.latitude = nil
            info.longitude = nil
        }
        return info
    }

    /// The country's flag, from its two letters. Empty without a country.
    public var flag: String {
        guard let code = countryCode, code.count == 2 else { return "" }
        let base: UInt32 = 0x1F1E6 - 65
        return String(String.UnicodeScalarView(code.unicodeScalars.compactMap { Unicode.Scalar(base + $0.value) }))
    }

    /// The country's English name (Cra's interface is English, #34), else its code.
    public var countryName: String? {
        guard let code = countryCode else { return nil }
        return Locale(identifier: "en_US").localizedString(forRegionCode: code) ?? code
    }

    /// "Tokyo, Tokyo, Japan" without the repeat: "Tokyo, Japan".
    public var place: String {
        var parts: [String] = []
        for p in [city, region, countryName].compactMap({ $0 }) where !parts.contains(p) { parts.append(p) }
        return parts.joined(separator: ", ")
    }

    /// The menu bar's title: "🇯🇵 203.0.113.7".
    public var menuTitle: String { flag.isEmpty ? ip : flag + " " + ip }

    public static func isIPAddress(_ s: String) -> Bool {
        if s.contains(":") {
            let allowed = s.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
            return allowed && s.count <= 45 && s.filter({ $0 == ":" }).count >= 2
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in
            !p.isEmpty && p.count <= 3 && p.allSatisfy { $0.isASCII && $0.isNumber } && Int(p).map { $0 <= 255 } == true
        }
    }
}

/// Where Cra asks for the exit address, and how often.
public enum ExitIPLookup {
    public static let defaultURL = "https://ipinfo.io/json"
    /// Services that need no key, for the Privacy pane's menu. All answer with the address, the
    /// country and the time zone except ipify, which has only the address.
    public static let services: [(name: String, url: String)] = [
        ("ipinfo.io", "https://ipinfo.io/json"),
        ("ipapi.co", "https://ipapi.co/json/"),
        ("ipwho.is", "https://ipwho.is/"),
        ("ifconfig.co", "https://ifconfig.co/json"),
        ("ipify (address only)", "https://api.ipify.org"),
    ]
    /// A check a minute while the menu shows the address; one at once when the proxy or the
    /// network changes.
    public static let interval: TimeInterval = 60
    /// Failures in a row before the menu says the profile is offline rather than just slow.
    public static let failuresBeforeOffline = 2

    /// A lookup address people can set: http or https with a host. Nil for anything else.
    public static func url(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: t), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

/// One profile's exit address as the menu bar shows it.
public enum ExitIPState: Equatable, Sendable {
    case unknown
    case checking
    case known(ExitIPInfo)
    /// The lookup failed (the proxy is down, or no network); the last address Cra saw, if any.
    case failed(last: ExitIPInfo?)

    /// The state after a lookup. A first failure keeps the address (a slow answer), the second
    /// in a row says the profile is offline.
    public static func after(_ previous: ExitIPState, result: ExitIPInfo?, failuresInARow: Int) -> ExitIPState {
        if let result = result { return .known(result) }
        let last: ExitIPInfo?
        switch previous {
        case .known(let info): last = info
        case .failed(let info): last = info
        case .unknown, .checking: last = nil
        }
        if failuresInARow < ExitIPLookup.failuresBeforeOffline, let last = last { return .known(last) }
        return .failed(last: last)
    }

    /// What to tell people when the address moves: the old and the new one. Nil for the first
    /// address, the same address, or a failure.
    public static func change(from old: ExitIPInfo?, to new: ExitIPInfo?) -> String? {
        guard let old = old, let new = new, old.ip != new.ip else { return nil }
        let place = new.place.isEmpty ? "" : " (\(new.place))"
        return "Exit IP changed from \(old.ip) to \(new.ip)\(place)."
    }
}

/// Privacy ▸ "Match the time zone to the exit IP": the time zone a profile's pages see
/// (Emulation.setTimezoneOverride), so a page behind a Tokyo proxy doesn't read a Shanghai clock.
public enum ExitTimeZone {
    /// The zone to give pages, or nil for the Mac's own.
    public static func override(enabled: Bool, info: ExitIPInfo?) -> String? {
        guard enabled, let zone = info?.timeZone, TimeZone(identifier: zone) != nil else { return nil }
        return zone
    }
}

import CraCore
import Foundation
import Testing

/// Privacy ▸ "Show the exit IP in the menu bar" and "Match the time zone to the exit IP" (not in Arc).
struct ExitIPTests {
    @Test func readsEachLookupService() throws {
        let ipinfo = try #require(ExitIPInfo.parse(#"{"ip":"203.0.113.7","city":"Tokyo","region":"Tokyo","country":"JP","loc":"35.6895,139.6917","org":"AS2516 KDDI CORPORATION","timezone":"Asia/Tokyo"}"#))
        #expect(ipinfo == ExitIPInfo(ip: "203.0.113.7", countryCode: "JP", region: "Tokyo", city: "Tokyo", organization: "AS2516 KDDI CORPORATION",
                                     timeZone: "Asia/Tokyo", latitude: 35.6895, longitude: 139.6917))
        let ipapi = try #require(ExitIPInfo.parse(#"{"ip":"198.51.100.4","city":"Frankfurt am Main","region":"Hesse","country":"DE","country_code":"DE","latitude":50.11,"longitude":8.68,"timezone":"Europe/Berlin","asn":"AS24940","org":"Hetzner Online GmbH"}"#))
        #expect(ipapi.countryCode == "DE" && ipapi.timeZone == "Europe/Berlin" && ipapi.organization == "AS24940 Hetzner Online GmbH")
        #expect(ipapi.latitude == 50.11 && ipapi.longitude == 8.68)
        let ipAPI = try #require(ExitIPInfo.parse(#"{"status":"success","query":"192.0.2.9","countryCode":"US","regionName":"California","city":"Los Angeles","lat":34.05,"lon":-118.24,"timezone":"America/Los_Angeles","isp":"Example ISP","org":"Example Org","as":"AS64500 Example"}"#))
        #expect(ipAPI.ip == "192.0.2.9" && ipAPI.region == "California" && ipAPI.timeZone == "America/Los_Angeles" && ipAPI.longitude == -118.24)
        let ipwho = try #require(ExitIPInfo.parse(#"{"ip":"2001:db8::7","success":true,"country":"Singapore","country_code":"SG","city":"Singapore","latitude":1.29,"longitude":103.85,"connection":{"asn":64501,"org":"Example SG"},"timezone":{"id":"Asia/Singapore"}}"#))
        #expect(ipwho.countryCode == "SG" && ipwho.timeZone == "Asia/Singapore" && ipwho.organization == "AS64501 Example SG")
        let ifconfig = try #require(ExitIPInfo.parse(#"{"ip":"192.0.2.33","country":"Japan","country_iso":"JP","region_name":"Osaka","city":"Osaka","time_zone":"Asia/Tokyo","asn":"AS2516","asn_org":"KDDI"}"#))
        #expect(ifconfig.countryCode == "JP" && ifconfig.region == "Osaka" && ifconfig.timeZone == "Asia/Tokyo" && ifconfig.organization == "AS2516 KDDI")
        // api.ipify.org and icanhazip.com answer with the address alone.
        #expect(ExitIPInfo.parse("203.0.113.7\n") == ExitIPInfo(ip: "203.0.113.7"))
    }

    @Test func refusesAnswersWithoutAnAddress() {
        #expect(ExitIPInfo.parse("") == nil)
        #expect(ExitIPInfo.parse("<html>blocked</html>") == nil)
        #expect(ExitIPInfo.parse(#"{"status":"fail","message":"reserved range","query":"10.0.0.1"}"#) == nil)
        #expect(ExitIPInfo.parse(#"{"success":false,"ip":"1.2.3.4"}"#) == nil)
        #expect(ExitIPInfo.parse(#"{"error":{"title":"Rate limit"}}"#) == nil)
        #expect(ExitIPInfo.parse(#"{"ip":"999.1.1.1"}"#) == nil)
        #expect(ExitIPInfo.parse("1.2.3") == nil)
    }

    @Test func dropsFieldsThatDontHold() throws {
        let info = try #require(ExitIPInfo.parse(#"{"ip":"203.0.113.7","country":"Japan","timezone":"Mars/Olympus","latitude":200,"longitude":5}"#))
        #expect(info.countryCode == nil && info.timeZone == nil && info.latitude == nil && info.longitude == nil)
    }

    @Test func showsTheAddressWithItsCountry() {
        let info = ExitIPInfo(ip: "203.0.113.7", countryCode: "JP", region: "Tokyo", city: "Tokyo")
        #expect(info.flag == "🇯🇵")
        #expect(info.menuTitle == "🇯🇵 203.0.113.7")
        #expect(info.place == "Tokyo, Japan")
        #expect(ExitIPInfo(ip: "203.0.113.7").menuTitle == "203.0.113.7")
        #expect(ExitIPInfo(ip: "203.0.113.7").place == "")
    }

    @Test func takesOnlyWebLookupAddresses() {
        #expect(ExitIPLookup.url("https://ipinfo.io/json")?.host == "ipinfo.io")
        #expect(ExitIPLookup.url(" http://127.0.0.1:8080/exit-ip.json ") != nil)
        #expect(ExitIPLookup.url("file:///etc/hosts") == nil)
        #expect(ExitIPLookup.url("ipinfo.io") == nil)
        #expect(ExitIPLookup.services.allSatisfy { ExitIPLookup.url($0.url) != nil })
        #expect(ExitIPLookup.url(ExitIPLookup.defaultURL) != nil)
    }

    /// A slow answer doesn't flip the menu to offline; two failures in a row do, and keep the last address.
    @Test func saysOfflineAfterTwoFailures() {
        let a = ExitIPInfo(ip: "203.0.113.7")
        #expect(ExitIPState.after(.unknown, result: a, failuresInARow: 0) == .known(a))
        #expect(ExitIPState.after(.known(a), result: nil, failuresInARow: 1) == .known(a))
        #expect(ExitIPState.after(.known(a), result: nil, failuresInARow: 2) == .failed(last: a))
        #expect(ExitIPState.after(.failed(last: a), result: nil, failuresInARow: 3) == .failed(last: a))
        #expect(ExitIPState.after(.checking, result: nil, failuresInARow: 1) == .failed(last: nil))
    }

    @Test func tellsWhenTheAddressMoves() {
        let a = ExitIPInfo(ip: "203.0.113.7")
        let b = ExitIPInfo(ip: "198.51.100.4", countryCode: "DE", city: "Frankfurt")
        #expect(ExitIPState.change(from: a, to: b) == "Exit IP changed from 203.0.113.7 to 198.51.100.4 (Frankfurt, Germany).")
        #expect(ExitIPState.change(from: nil, to: b) == nil)
        #expect(ExitIPState.change(from: a, to: a) == nil)
        #expect(ExitIPState.change(from: a, to: nil) == nil)
    }

    @Test func givesPagesTheExitTimeZone() {
        let tokyo = ExitIPInfo(ip: "203.0.113.7", timeZone: "Asia/Tokyo")
        #expect(ExitTimeZone.override(enabled: true, info: tokyo) == "Asia/Tokyo")
        #expect(ExitTimeZone.override(enabled: false, info: tokyo) == nil)
        #expect(ExitTimeZone.override(enabled: true, info: ExitIPInfo(ip: "203.0.113.7")) == nil)
        #expect(ExitTimeZone.override(enabled: true, info: nil) == nil)
    }

    @Test func newSettingsAreNamedInUsageStatsLists() {
        for key in ["webRTCAlwaysProxied", "exitIPInMenuBar", "matchTimeZoneToExitIP"] { #expect(UsageStats.reportedSettings.contains(key)) }
        #expect(UsageStats.unreportedSettings.contains("exitIPLookupURL"))
        let s = AppSettings()
        #expect(!s.webRTCAlwaysProxied && !s.exitIPInMenuBar && !s.matchTimeZoneToExitIP && s.exitIPLookupURL == ExitIPLookup.defaultURL)
        let decoded = try? JSONDecoder().decode(AppSettings.self, from: Data(#"{"exitIPInMenuBar": true, "exitIPLookupURL": "https://ipwho.is/"}"#.utf8))
        #expect(decoded?.exitIPInMenuBar == true && decoded?.exitIPLookupURL == "https://ipwho.is/")
    }
}

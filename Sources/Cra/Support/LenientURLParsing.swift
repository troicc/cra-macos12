import Foundation
import ObjectiveC

/// macOS 14 parses URL strings by RFC 3986 and percent-encodes what isn't allowed in one, so
/// `URL(string: "https://www.baidu.com/s?wd=中文")`, a space, `|`, `{` or `"` give a URL. Cra is
/// written and tested against that. macOS 12 and 13 still parse by RFC 1738/1808 and return nil
/// for all of those, so on them a link with Chinese in it, a cra:// command with JSON in it
/// (every `cdp=…&params={…}` of the scenarios) and many others quietly did nothing.
///
/// On macOS 12 and 13 this gives NSURL and NSURLComponents (what Swift's `URL(string:)` and
/// `URLComponents(string:)` call there) the newer behaviour: a string the old parser takes is
/// left alone; one it rejects is retried with the characters it rejects percent-encoded, a `%`
/// that starts no escape becoming `%25`, as macOS 14 does.
enum LenientURLParsing {
    /// Once, first thing in main.swift.
    static func install() {
        if #available(macOS 14.0, *) { return }
        wrap(NSURL.self, "initWithString:relativeToURL:", withBase: true)
        wrap(NSURL.self, "initWithString:", withBase: false)
        // NSURLComponents is a class cluster: alloc hands out its concrete subclass.
        var seen = Set<OpaquePointer>()
        for cls in [NSClassFromString("__NSConcreteURLComponents"), NSURLComponents.self].compactMap({ $0 }) {
            guard let m = class_getInstanceMethod(cls, NSSelectorFromString("initWithString:")),
                  seen.insert(m).inserted else { continue }
            wrap(m, withBase: false, components: true)
        }
    }

    private static func wrap(_ cls: AnyClass, _ selector: String, withBase: Bool) {
        guard let m = class_getInstanceMethod(cls, NSSelectorFromString(selector)) else { return }
        wrap(m, withBase: withBase, components: false)
    }

    /// Raw pointers throughout: an init consumes self and returns +1, which ARC must not touch.
    private static func wrap(_ m: Method, withBase: Bool, components: Bool) {
        let original = method_getImplementation(m)
        let sel = method_getName(m)
        if withBase {
            typealias Fn = @convention(c) (OpaquePointer, Selector, OpaquePointer?, OpaquePointer?) -> OpaquePointer?
            let call = unsafeBitCast(original, to: Fn.self)
            let block: @convention(block) (OpaquePointer, OpaquePointer?, OpaquePointer?) -> OpaquePointer? = { me, string, base in
                guard let fixed = repaired(string, base: base, components: false) else { return call(me, sel, string, base) }
                return withExtendedLifetime(fixed) { call(me, sel, OpaquePointer(Unmanaged.passUnretained(fixed).toOpaque()), base) }
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        } else {
            typealias Fn = @convention(c) (OpaquePointer, Selector, OpaquePointer?) -> OpaquePointer?
            let call = unsafeBitCast(original, to: Fn.self)
            let block: @convention(block) (OpaquePointer, OpaquePointer?) -> OpaquePointer? = { me, string in
                guard let fixed = repaired(string, base: nil, components: components) else { return call(me, sel, string) }
                return withExtendedLifetime(fixed) { call(me, sel, OpaquePointer(Unmanaged.passUnretained(fixed).toOpaque())) }
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
    }

    /// The string to parse instead, nil to parse the one given.
    private static func repaired(_ pointer: OpaquePointer?, base: OpaquePointer?, components: Bool) -> NSString? {
        guard let pointer = pointer else { return nil }
        let object = Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(pointer)).takeUnretainedValue()
        guard let ns = object as? NSString, ns.length > 0 else { return nil }
        let string = ns as String
        // Fast path: nothing the old parser could object to.
        guard needsLook(string) else { return nil }
        let baseURL = base.map { Unmanaged<NSURL>.fromOpaque(UnsafeRawPointer($0)).takeUnretainedValue() as CFURL }
        func parses(_ s: String) -> Bool { CFURLCreateWithString(nil, s as CFString, baseURL) != nil }
        if parses(string) { return nil }
        for strict in [false, true] {
            let fixed = encode(string, strict: strict)
            if fixed != string, parses(fixed) { return fixed as NSString }
        }
        return nil
    }

    // RFC 3986's unreserved and reserved characters, and %.
    private static let allowed: Set<UInt8> = Set(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%".utf8))
    private static let hex: Set<UInt8> = Set(Array("0123456789abcdefABCDEF".utf8))

    private static func needsLook(_ s: String) -> Bool {
        let bytes = Array(s.utf8)
        for (i, b) in bytes.enumerated() {
            if !allowed.contains(b) || b == UInt8(ascii: "[") || b == UInt8(ascii: "]") || b == UInt8(ascii: "#") { return true }
            if b == UInt8(ascii: "%"), !(i + 2 < bytes.count && hex.contains(bytes[i + 1]) && hex.contains(bytes[i + 2])) { return true }
        }
        return false
    }

    /// Percent-encodes, as UTF-8, every byte outside the allowed set and a `%` that starts no escape.
    /// `strict` also encodes `[` and `]` after the authority, and any `#` after the first.
    private static func encode(_ s: String, strict: Bool) -> String {
        let bytes = Array(s.utf8)
        // Where the authority ends: after "scheme://host[:port]", the first "/", "?" or "#".
        var authorityEnd = 0
        if let r = s.range(of: "://") {
            let start = s.utf8.distance(from: s.utf8.startIndex, to: r.upperBound)
            authorityEnd = bytes[start...].firstIndex(where: { $0 == UInt8(ascii: "/") || $0 == UInt8(ascii: "?") || $0 == UInt8(ascii: "#") }) ?? bytes.count
        }
        var out = [UInt8]()
        out.reserveCapacity(bytes.count + 16)
        var sawHash = false
        for (i, b) in bytes.enumerated() {
            var escape = !allowed.contains(b)
            if b == UInt8(ascii: "%") {
                escape = !(i + 2 < bytes.count && hex.contains(bytes[i + 1]) && hex.contains(bytes[i + 2]))
            }
            if strict, i >= authorityEnd {
                if b == UInt8(ascii: "[") || b == UInt8(ascii: "]") { escape = true }
                if b == UInt8(ascii: "#") { if sawHash { escape = true } else { sawHash = true } }
            }
            if escape {
                out.append(UInt8(ascii: "%"))
                out.append(contentsOf: Array(String(format: "%02X", b).utf8))
            } else {
                out.append(b)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

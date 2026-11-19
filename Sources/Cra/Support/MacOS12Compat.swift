import AppKit
import SwiftUI
import Perception

extension Task where Success == Never, Failure == Never {
    /// macOS 12-compatible sleep in seconds (replaces macOS 13+ `Task.sleep(for: .seconds(...))`).
    static func compatSleep(seconds: Double) async throws {
        let nanos = UInt64(max(0, seconds) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanos)
    }

    /// macOS 12-compatible sleep in milliseconds (replaces macOS 13+ `Task.sleep(for: .milliseconds(...))`).
    static func compatSleep(milliseconds: Double) async throws {
        let nanos = UInt64(max(0, milliseconds) * 1_000_000)
        try await Task.sleep(nanoseconds: nanos)
    }
}

enum CompatScrollIndicatorVisibility {
    case automatic
    case visible
    case hidden
    case never
}

extension View {
    @ViewBuilder
    func compatScrollIndicators(_ visibility: CompatScrollIndicatorVisibility) -> some View {
        if #available(macOS 13.0, *) {
            switch visibility {
            case .automatic: self.scrollIndicators(.automatic)
            case .visible: self.scrollIndicators(.visible)
            case .hidden: self.scrollIndicators(.hidden)
            case .never: self.scrollIndicators(.never)
            }
        } else {
            self
        }
    }

    @ViewBuilder
    func compatFontWeight(_ weight: Font.Weight?) -> some View {
        if #available(macOS 13.0, *) {
            self.fontWeight(weight)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatMenuButtonStyle() -> some View {
        if #available(macOS 13.0, *) {
            self.menuStyle(.button)
        } else {
            self.menuStyle(.borderlessButton)
        }
    }

    @ViewBuilder
    func compatPresentationBackgroundRegularMaterial() -> some View {
        if #available(macOS 13.3, *) {
            self.presentationBackground(.regularMaterial)
        } else {
            self.background(.regularMaterial)
        }
    }

    @ViewBuilder
    func compatOnGeometryChange<T: Equatable>(
        for type: T.Type,
        of transform: @escaping (GeometryProxy) -> T,
        action: @escaping (T) -> Void
    ) -> some View {
        if #available(macOS 13.0, *) {
            self.onGeometryChange(for: type, of: transform, action: action)
        } else {
            self.background(
                GeometryReader { proxy in WithPerceptionTracking {
                    let value = transform(proxy)
                    Color.clear
                        .onAppear { action(value) }
                        .onChange(of: value) { newValue in action(newValue) }
                } }
            )
        }
    }
}

// MARK: - macOS 12 CASpringAnimation shim (replaces macOS 14+ init(perceptualDuration:bounce:))

extension CASpringAnimation {
    static func compat(perceptualDuration: CFTimeInterval, bounce: CGFloat) -> CASpringAnimation {
        if #available(macOS 14.0, *) {
            return CASpringAnimation(perceptualDuration: perceptualDuration, bounce: bounce)
        }
        let anim = CASpringAnimation()
        let response = max(0.05, perceptualDuration)
        let dampingRatio = max(0.1, min(1.0, 1.0 - bounce))
        let omega = 2.0 * .pi / response
        anim.mass = 1.0
        anim.stiffness = CGFloat(omega * omega)
        anim.damping = CGFloat(2.0 * Double(dampingRatio) * omega)
        return anim
    }
}

// MARK: - macOS 12 DisplayLink shim (replaces macOS 14+ CADisplayLink)

final class CompatDisplayLink: NSObject {
    private var caLink: AnyObject?
    private var timer: Timer?
    private weak var target: AnyObject?
    private var selector: Selector?
    private(set) var timestamp: CFTimeInterval = CACurrentMediaTime()
    private(set) var targetTimestamp: CFTimeInterval = CACurrentMediaTime() + (1.0 / 60.0)

    init(view: NSView, target: AnyObject, selector: Selector) {
        self.target = target
        self.selector = selector
        super.init()
        if #available(macOS 14.0, *) {
            self.caLink = view.displayLink(target: self, selector: #selector(caTick(_:)))
        }
    }

    func add(to runloop: RunLoop, forMode mode: RunLoop.Mode) {
        if #available(macOS 14.0, *), let link = caLink as? CADisplayLink {
            link.add(to: runloop, forMode: mode)
            return
        }
        let t = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(timerTick), userInfo: nil, repeats: true)
        runloop.add(t, forMode: mode)
        timer = t
    }

    func invalidate() {
        if #available(macOS 14.0, *), let link = caLink as? CADisplayLink {
            link.invalidate()
            caLink = nil
        }
        timer?.invalidate()
        timer = nil
    }

    @available(macOS 14.0, *)
    @objc private func caTick(_ link: CADisplayLink) {
        timestamp = link.timestamp
        targetTimestamp = link.targetTimestamp
        guard let target, let selector else { invalidate(); return }
        _ = target.perform(selector, with: self)
    }

    @objc private func timerTick() {
        let now = CACurrentMediaTime()
        timestamp = now
        targetTimestamp = now + (1.0 / 60.0)
        guard let target, let selector else { invalidate(); return }
        _ = target.perform(selector, with: self)
    }
}

extension NSView {
    func compatDisplayLink(target: AnyObject, selector: Selector) -> CompatDisplayLink {
        CompatDisplayLink(view: self, target: target, selector: selector)
    }
}

struct CompatURLDropModifier: ViewModifier {
    let onDrop: (URL) -> Void

    func body(content: Content) -> some View { WithPerceptionTracking {
        if #available(macOS 13.0, *) {
            content.dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                onDrop(url)
                return true
            }
        } else {
            content
        }
    } }
}

extension CGRect {
    /// Like `insetBy(dx:dy:)` but clamps size to >= 0 instead of returning `CGRect.null` (+inf),
    /// which triggers an `NSView setFrameOrigin:` `isfinite(newOrigin.x)` assertion on macOS 12.
    func safeInsetBy(dx: CGFloat, dy: CGFloat) -> CGRect {
        let w = width - 2 * dx
        let h = height - 2 * dy
        if w <= 0 || h <= 0 {
            return CGRect(x: origin.x + min(dx, width / 2), y: origin.y + min(dy, height / 2),
                          width: max(0, w), height: max(0, h))
        }
        return insetBy(dx: dx, dy: dy)
    }
}

extension NSView {
    /// macOS 12-compatible wrapper around macOS 14+ `NSView.clipsToBounds`.
    var compatClipsToBounds: Bool {
        get {
            if #available(macOS 14.0, *) {
                return clipsToBounds
            }
            return layer?.masksToBounds ?? false
        }
        set {
            if #available(macOS 14.0, *) {
                clipsToBounds = newValue
            } else {
                wantsLayer = true
                layer?.masksToBounds = newValue
            }
        }
    }
}

/// macOS 12-compatible SwiftUI-to-NSImage renderer (uses `ImageRenderer` on macOS 13+).
@MainActor
func compatRenderSwiftUIImage<V: View>(_ view: V, scale: CGFloat = 2) -> NSImage? {
    if #available(macOS 13.0, *) {
        let r = ImageRenderer(content: view)
        r.scale = scale
        return r.nsImage
    }
    let host = NSHostingView(rootView: view)
    let size = host.fittingSize
    guard size.width > 0, size.height > 0 else { return nil }
    host.frame = CGRect(origin: .zero, size: size)
    // Attach to an offscreen window so SwiftUI's displayScale and CALayer contentsScale pick up
    // the Retina backing scale instead of rasterizing SF Symbols and shapes at 1x.
    let win = NSWindow(
        contentRect: CGRect(origin: .zero, size: size),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    win.isReleasedWhenClosed = false
    win.isOpaque = false
    win.backgroundColor = .clear
    win.contentView = host
    host.layoutSubtreeIfNeeded()
    let pxW = max(1, Int((size.width * scale).rounded()))
    let pxH = max(1, Int((size.height * scale).rounded()))
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pxW,
        pixelsHigh: pxH,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
    rep.size = size
    host.cacheDisplay(in: host.bounds, to: rep)
    let img = NSImage(size: size)
    img.addRepresentation(rep)
    return img
}

// MARK: - macOS 12 EnvironmentKey shims for @Perceptible objects (replaces macOS 14+ @Environment(T.self))

private struct CompatSidebarStoreKey: EnvironmentKey {
    static let defaultValue: SidebarStore? = nil
}

private struct CompatFaviconCacheKey: EnvironmentKey {
    static let defaultValue: FaviconCache? = nil
}

private struct CompatKeyBindingRegistryKey: EnvironmentKey {
    static let defaultValue: KeyBindingRegistry = .shared
}

private struct CompatSettingsSyncServiceKey: EnvironmentKey {
    static let defaultValue: SettingsSyncService? = nil
}

extension EnvironmentValues {
    /// Writable optional box used with `.environment(\.compatSidebarStoreBox, store)` so SwiftUI's
    /// `WritableKeyPath` copy-in getter never force-unwraps `nil` before writing.
    var compatSidebarStoreBox: SidebarStore? {
        get { self[CompatSidebarStoreKey.self] }
        set { self[CompatSidebarStoreKey.self] = newValue }
    }

    var compatSidebarStore: SidebarStore {
        self[CompatSidebarStoreKey.self]!
    }

    var compatFaviconsBox: FaviconCache? {
        get { self[CompatFaviconCacheKey.self] }
        set { self[CompatFaviconCacheKey.self] = newValue }
    }

    var compatFavicons: FaviconCache {
        self[CompatFaviconCacheKey.self]!
    }

    var compatBindings: KeyBindingRegistry {
        get { self[CompatKeyBindingRegistryKey.self] }
        set { self[CompatKeyBindingRegistryKey.self] = newValue }
    }

    var compatSyncBox: SettingsSyncService? {
        get { self[CompatSettingsSyncServiceKey.self] }
        set { self[CompatSettingsSyncServiceKey.self] = newValue }
    }

    var compatSync: SettingsSyncService {
        self[CompatSettingsSyncServiceKey.self]!
    }
}


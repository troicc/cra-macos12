import AppKit
import SwiftUI

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
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
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
    var compatSidebarStore: SidebarStore {
        get { self[CompatSidebarStoreKey.self]! }
        set { self[CompatSidebarStoreKey.self] = newValue }
    }

    var compatFavicons: FaviconCache {
        get { self[CompatFaviconCacheKey.self]! }
        set { self[CompatFaviconCacheKey.self] = newValue }
    }

    var compatBindings: KeyBindingRegistry {
        get { self[CompatKeyBindingRegistryKey.self] }
        set { self[CompatKeyBindingRegistryKey.self] = newValue }
    }

    var compatSync: SettingsSyncService {
        get { self[CompatSettingsSyncServiceKey.self]! }
        set { self[CompatSettingsSyncServiceKey.self] = newValue }
    }
}


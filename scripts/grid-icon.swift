// macOS 11–15 draw a bundle's AppIcon.icns as it is; only macOS 26 shrinks an edge-to-edge
// icon onto Apple's grid by itself. This puts resources/AppIcon.icns's edge-to-edge tile on
// the grid (824 of 1024 px, centred, with the soft drop shadow Big Sur icons have) so Cra's
// icon is the same size as every other app's in the Dock, Finder and ⌘-Tab on macOS 12.
//   swift scripts/grid-icon.swift <edge-to-edge 1024 px PNG> <out folder>
// writes <out folder>/AppIcon.icns.
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let source = NSImage(contentsOfFile: args[1]) else {
    print("usage: swift scripts/grid-icon.swift <1024 px PNG> <out folder>"); exit(1)
}
let out = args[2]
let body: CGFloat = 824.0 / 1024

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let size = CGFloat(px)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    let side = size * body
    let tile = NSRect(x: (size - side) / 2, y: (size - side) / 2, width: side, height: side)
    // Same 14.3-on-64 corners as the source tile, clipped again so no square edge survives scaling.
    let radius = side * 14.3 / 64
    let path = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
    // Apple's template shadow: straight down, soft, light. Skipped where it would only blur (≤ 32 px).
    if px > 32 {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = size * 10 / 1024
        shadow.shadowOffset = NSSize(width: 0, height: -size * 10 / 1024)
        shadow.set()
        NSColor(srgbRed: 0.91, green: 0.83, blue: 0.67, alpha: 1).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    source.draw(in: tile, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let set = out + "/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: set)
try! FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128),
                   ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(set)/\(name).png"))
}
let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", set, "-o", out + "/AppIcon.icns"]
task.launch(); task.waitUntilExit()
print("wrote \(out)/AppIcon.icns")
